import FileProvider
import Foundation
import MyDriveCore

struct CapturedDeletionConflict: Error, Sendable {
    let message: String
}

extension ProviderMutations {
    func delete(id: String, contentVersion: Data, metadataVersion: Data, progress: Progress) async throws {
        try await checkActive()
        guard id != Catalog.rootID else { throw CocoaError(.fileWriteNoPermission) }
        try await refuseUnsupportedPackageDeletion(id: id)
        let key = MutationInput.deletionID(id: id, content: contentVersion, metadata: metadataVersion)
        let operation: JournalOperation
        if let existing = try await catalog.operation(key: key) { operation = existing }
        else {
            guard let item = try await catalog.item(id: id), !item.isDeleted,
                  let parent = item.parentID, let path = try await catalog.relativePath(id: id) else { return }
            let parentIdentity = try await preparation.verifiedParent(parent)
            guard let observed = try await remote.stat(path) else {
                // A definite missing path is reconciled into Catalog through the
                // same durable publication path, not reported as a NAS outage.
                let intent = JournalIntent(idempotencyKey: key, itemID: id,
                    expectedVersion: item.entry.contentVersion, action: .delete,
                    expectedMetadataVersion: item.entry.metadataVersion, sourcePath: path, baseEntry: item.entry)
                _ = try await catalog.enqueue(intent)
                _ = try await catalog.transitionOperation(key: key, from: .queued, to: .executing)
                _ = try await catalog.commitMutation(key: key, upserts: [], tombstones: [id])
                progress.completedUnitCount = 1
                return
            }
            guard MutationPreparation.matches(observed, content: contentVersion, metadata: metadataVersion) else {
                throw try await deletionRejected(id: id, parentID: parent, entry: observed.observation)
            }
            try MutationPreparation.requireOrdinary(observed)
            let intent = JournalIntent(idempotencyKey: key, itemID: id,
                expectedVersion: item.entry.contentVersion, action: .delete,
                expectedMetadataVersion: item.entry.metadataVersion, sourcePath: path, baseEntry: item.entry)
            let request = SMBMutationRequest(operationID: key, kind: .delete, path: path, parent: parentIdentity, expected: observed)
            try staging.save(MutationPlan(key: key, itemID: id, parentID: parent,
                                         filename: item.entry.name, steps: [.init(request: request)], preservedOriginal: nil))
            operation = try await catalog.enqueue(intent)
        }
        if try await catalog.mutationResult(key: operation.intent.idempotencyKey) != nil {
            if var plan = try staging.load(operation.intent.idempotencyKey) {
                await cleanup(plan: &plan)
                try requirePermanentDeletion(plan)
            }
            progress.completedUnitCount = 1; return
        }
        guard var plan = try staging.load(operation.intent.idempotencyKey) else {
            throw MutationInput.unsupported("An interrupted deletion needs attention before it can be retried.")
        }
        if operation.state == .queued {
            _ = try await catalog.transitionOperation(key: plan.key, from: .queued, to: .executing)
        }
        do {
            try await performStep(0, plan: &plan, recovering: operation.state != .queued, progress: nil)
            if plan.steps[0].result?.code == "parent_changed" { throw MutationParentError.replaced(plan.parentID) }
            if plan.steps[0].result?.outcome == .conflict,
               let entry = try await remote.stat(plan.steps[0].request.path) {
                throw try await deletionRejected(id: id, parentID: plan.parentID, entry: entry.observation)
            }
            try requireCommitted(plan.steps[0], deleting: true, parentID: plan.parentID)
            try await checkActive()
            _ = try await catalog.commitMutation(key: plan.key, upserts: [], tombstones: [id])
            await cleanup(plan: &plan)
            try requirePermanentDeletion(plan)
            progress.completedUnitCount = 1
        } catch {
            if let latest = try? await catalog.operation(key: plan.key), latest.state == .executing {
                _ = try? await catalog.transitionOperation(key: plan.key, from: .executing, to: .uncertain)
            }
            throw error
        }
    }


    /// A manifest child uses the ordinary durable mutation journal and transport
    /// receipts. Only Core's manifest progress transaction retires its Catalog
    /// node, after permanent absence and artifact cleanup have been confirmed.
    func deleteCaptured(rootKey: UUID, item: CatalogItem, path: String,
                        parentIdentity: RemoteObjectIdentity, operationKey: UUID,
                        scope: SMBDeleteScope) async throws -> UUID {
        try await checkActive()
        var operation: JournalOperation
        if let existing = try await catalog.operation(key: operationKey) {
            operation = try await catalog.enqueueRecursiveDeleteChild(key: rootKey, itemID: item.id, intent: existing.intent)
        } else {
            let current = try await remote.scopedStat(path, scope)
            let expected: SMBEntry?
            if let current {
                guard current.objectIdentity == item.entry.objectIdentity,
                      current.directory == (item.entry.kind == .directory) else {
                    throw CapturedDeletionConflict(message: "An item in the selected folder changed during deletion. The remaining items are preserved.")
                }
                try MutationPreparation.requireOrdinary(current)
                if current.directory {
                    let listed = try await remote.scopedList(path, scope) { entries in
                        guard entries.isEmpty else { throw NSFileProviderError(.directoryNotEmpty) }
                    }
                    guard listed.objectIdentity == item.entry.objectIdentity else { throw SMBClientError.scopeChanged }
                    expected = listed
                } else {
                    guard MutationPreparation.matches(current, content: Data(item.entry.contentVersion.utf8),
                        metadata: Data(item.entry.metadataVersion.utf8)) else {
                        throw CapturedDeletionConflict(message: "A file changed after deletion was prepared. Its new contents and the remaining folder are preserved.")
                    }
                    expected = current
                }
            } else { expected = nil }
            let base = expected?.observation ?? item.entry
            let intent = JournalIntent(idempotencyKey: operationKey, itemID: item.id,
                expectedVersion: base.contentVersion, action: .delete,
                expectedMetadataVersion: base.metadataVersion, sourcePath: path, baseEntry: base)
            var plan = MutationPlan(key: operationKey, itemID: item.id,
                parentID: item.parentID ?? Catalog.rootID, filename: item.entry.name,
                steps: expected.map { [.init(request: SMBMutationRequest(operationID: operationKey,
                    kind: .delete, path: path, parent: .init(parentIdentity), expected: $0, deleteScope: scope))] } ?? [],
                preservedOriginal: nil)
            plan.readOnlyDeletionAbsence = expected == nil
            try staging.save(plan)
            operation = try await catalog.enqueueRecursiveDeleteChild(key: rootKey, itemID: item.id, intent: intent)
            if operation.intent.idempotencyKey != operationKey { try? staging.removePlan(operationKey) }
        }
        let key = operation.intent.idempotencyKey
        var loaded = try staging.load(key)
        if var plan = loaded {
            try narrowCapturedPlan(&plan, item: item, path: path, parent: .init(parentIdentity), scope: scope)
            try staging.save(plan)
            loaded = plan
        }
        if try await catalog.mutationResult(key: key) != nil {
            if var plan = loaded { await cleanup(plan: &plan, retirePlan: false); try requirePermanentDeletion(plan) }
            if try await remote.scopedStat(path, scope) != nil {
                throw CapturedDeletionConflict(message: "The completed deletion's pathname contains a new item. It is preserved.")
            }
            return key
        }
        guard var plan = loaded else {
            throw MutationInput.unsupported("The deletion recovery record is unavailable. Remaining NAS items are preserved.")
        }
        let recovering = operation.state != .queued
        if operation.state == .failed {
            operation = try await catalog.transitionOperation(key: key, from: .failed, to: .queued)
        }
        if operation.state == .queued { _ = try await catalog.transitionOperation(key: key, from: .queued, to: .executing) }
        do {
            if plan.readOnlyDeletionAbsence {
                guard plan.steps.isEmpty, try await remote.scopedStat(path, scope) == nil else {
                    throw CapturedDeletionConflict(message: "The NAS pathname changed after deletion was prepared. The replacement is preserved.")
                }
            } else {
                guard plan.steps.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
                try await performStep(0, plan: &plan, recovering: recovering, progress: nil)
                if plan.steps[0].result?.outcome == .conflict,
                   !["scope_changed", "parent_changed"].contains(plan.steps[0].result?.code ?? "") {
                    throw CapturedDeletionConflict(message: "The NAS item changed during deletion. Its current contents are preserved.")
                }
                try requireCommitted(plan.steps[0], deleting: true, parentID: plan.parentID)
                await cleanup(plan: &plan, retirePlan: false)
                try requirePermanentDeletion(plan)
                guard try await remote.scopedStat(path, scope) == nil else {
                    throw CapturedDeletionConflict(message: "The deletion's pathname contains a new item. It is preserved.")
                }
            }
            try await checkActive()
            return key
        } catch {
            if let latest = try? await catalog.operation(key: key), latest.state == .executing {
                _ = try? await catalog.transitionOperation(key: key, from: .executing, to: .uncertain)
            }
            throw error
        }
    }

    /// Called only after Core atomically stored the child's completion receipt.
    /// Interrupted retirement is also handled by ordinary bounded maintenance.
    func finishCapturedDelete(_ key: UUID) { try? staging.removePlan(key) }

    /// Core may deduplicate against an ordinary delete created earlier. Adding
    /// selection fences is a narrowing only: preserve its wire UUID, expected
    /// target, immediate parent and exact receipts before any replay or cleanup.
    private func narrowCapturedPlan(_ plan: inout MutationPlan, item: CatalogItem, path: String,
                                    parent: SMBMutationRequest.ParentIdentity, scope: SMBDeleteScope) throws {
        guard plan.itemID.utf8.elementsEqual(item.id.utf8), plan.localRecovery == nil,
              (plan.readOnlyDeletionAbsence ? plan.steps.isEmpty : plan.steps.count == 1) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func narrow(_ request: SMBMutationRequest) throws -> SMBMutationRequest {
            guard request.kind == .delete, request.path.utf8.elementsEqual(path.utf8), request.parent == parent,
                  let expected = request.expected, expected.objectIdentity == item.entry.objectIdentity,
                  expected.directory == (item.entry.kind == .directory),
                  request.delete_scope == nil || request.delete_scope == scope,
                  request.receipt.staged == nil,
                  let wireID = UUID(uuidString: request.operation_id) else { throw SMBClientError.scopeChanged }
            if !expected.directory, !MutationPreparation.matches(expected, content: Data(item.entry.contentVersion.utf8),
                metadata: Data(item.entry.metadataVersion.utf8)) { throw SMBClientError.scopeChanged }
            if let archive = request.receipt.archived, !scope.contains(archive.path) { throw SMBClientError.scopeChanged }
            return SMBMutationRequest(operationID: wireID, kind: .delete,
                path: request.path, parent: request.parent, expected: expected, receipt: request.receipt, deleteScope: scope)
        }
        for index in plan.steps.indices { plan.steps[index].request = try narrow(plan.steps[index].request) }
        plan.retainedRequests = try plan.retainedRequests.map(narrow)
    }
}
