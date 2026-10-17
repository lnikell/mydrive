import Foundation
import MyDriveCore

extension ProviderTreeImport {
    /// The arena is the published payload root. After publication only local
    /// plans/input are retired; no old scope is repointed to the new pathname.
    func cleanPublished(_ plan: inout MutationPlan, status supplied: TreeImportStatus? = nil) async {
        do {
            let current: TreeImportStatus?
            if let supplied { current = supplied }
            else { current = try await mutations.catalog.treeImportStatus(rootID: plan.itemID) }
            guard var retained = plan.treeImport, retained.layoutVersion == 2,
                  let status = current, status.layoutVersion == 2, status.phase == .published,
                  status.key == plan.key, status.tree == retained.tree, plan.steps.isEmpty else { return }
            if !retained.localRetirementStarted {
                let snapshot = try LocalTreeSnapshot.load(retained.tree, in: mutations.staging)
                try await retirePublishedPlans(status, snapshot: snapshot)
                retained.localRetirementStarted = true
                plan.treeImport = retained
                // Fsync before removing the local index: a restart can finish
                // partial directory removal without needing that index again.
                try mutations.staging.save(plan)
            }
            guard try await publishedPlansRetired(status) else { return }
            try await mutations.checkActive()
            try LocalTreeSnapshot.retirePublished(retained.tree, in: mutations.staging)
            try mutations.staging.removePlan(plan.key)
        } catch { /* Local receipt/input retirement remains resumable. */ }
    }
}
