import Foundation
import MyDriveCore

extension ProviderTreeImport {
    /// Every historical child needs its exact plan. An absent pathname never
    /// authorizes lost allocation. Run before verification and final rename.
    func settleChildren(_ status: TreeImportStatus, publishing: UUID? = nil) async throws {
        guard status.layoutVersion == 2, let root = try mutations.staging.load(status.key),
              let retained = root.treeImport, retained.layoutVersion == 2,
              retained.tree == status.tree, retained.saveContract == status.saveContract else { throw unfinishedTree() }
        let snapshot = try LocalTreeSnapshot.load(retained.tree, in: mutations.staging)
        var cursor: Int64?
        while true {
            try await mutations.checkActive()
            let page = try await mutations.catalog.treeImportOperations(key: status.key, afterSequence: cursor, limit: 128)
            guard let last = page.last else { break }
            for bound in page {
                try await mutations.checkActive()
                let key = bound.operation.intent.idempotencyKey
                guard var plan = try mutations.staging.load(key) else { throw unfinishedTree() }
                try qualify(plan, step: bound.step, intent: bound.operation.intent,
                    parent: bound.parentIdentity, destinationParent: bound.destinationParentIdentity,
                    status: status, snapshot: snapshot)
                if bound.step == .publish, key == publishing {
                    // Reconcile this same move after a lost publication reply;
                    // earlier children cannot receive this state exception.
                    guard noUncertainArtifacts(plan), plan.steps[0].request.payload == nil else { throw unfinishedTree() }
                    continue
                }
                guard bound.operation.state == .completed,
                      let result = plan.steps[0].result, result.outcome == .committed,
                      let completed = try await mutations.catalog.mutationResult(key: key), let receipt = completed.items.first,
                      result.content_evidence == completed.contentEvidence,
                      Self.matches(result.entry, base: receipt.entry) else { throw unfinishedTree() }
                await mutations.cleanup(plan: &plan, retirePlan: false)
                guard noUncertainArtifacts(plan), artifactsClean(plan) else { throw unfinishedTree() }
            }
            cursor = last.sequence
        }
    }

    /// Root commit is durable. Perform local retirement only; already retired
    /// clean children may be absent after a crash during this pass.
    func retirePublishedPlans(_ status: TreeImportStatus, snapshot: LocalTreeSnapshot) async throws {
        var cursor: Int64?
        while true {
            try await mutations.checkActive()
            let page = try await mutations.catalog.treeImportOperations(key: status.key, afterSequence: cursor, limit: 128)
            guard let last = page.last else { break }
            for bound in page {
                let key = bound.operation.intent.idempotencyKey
                guard bound.operation.state == .completed else { throw unfinishedTree() }
                guard let plan = try mutations.staging.load(key) else { continue }
                try qualify(plan, step: bound.step, intent: bound.operation.intent,
                    parent: bound.parentIdentity, destinationParent: bound.destinationParentIdentity,
                    status: status, snapshot: snapshot)
                guard noUncertainArtifacts(plan), artifactsClean(plan) else { throw unfinishedTree() }
                try mutations.staging.removePlan(key)
            }
            cursor = last.sequence
        }
    }

    func publishedPlansRetired(_ status: TreeImportStatus) async throws -> Bool {
        var cursor: Int64?
        while true {
            try await mutations.checkActive()
            let page = try await mutations.catalog.treeImportOperations(key: status.key, afterSequence: cursor, limit: 128)
            guard let last = page.last else { return true }
            for bound in page {
                guard bound.operation.state == .completed,
                      try mutations.staging.load(bound.operation.intent.idempotencyKey) == nil else { return false }
            }
            cursor = last.sequence
        }
    }

    private func noUncertainArtifacts(_ plan: MutationPlan) -> Bool {
        plan.unresolvedAllocationPaths.isEmpty && plan.retainedRequests.isEmpty && plan.localRecovery == nil
    }

    private func artifactsClean(_ plan: MutationPlan) -> Bool {
        plan.cleanupCandidates.allSatisfy { $0.artifact.cleanup_safe && plan.cleanedArtifacts.contains($0.artifact.path) }
    }

    private func unfinishedTree() -> NSError {
        MutationInput.unsupported("This folder import has unfinished recovery or cleanup evidence. Its local contents and NAS staging records are preserved.")
    }
}
