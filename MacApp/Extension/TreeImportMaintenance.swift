import Foundation
import MyDriveCore

extension ProviderTreeImport {
    /// Indexed lineage restores immutable parent/request authority; a current
    /// live Catalog path or artifact absence cannot replace that evidence.
    func qualifyChildCleanup(_ plan: MutationPlan, status: TreeImportStatus) async throws {
        guard status.layoutVersion == 2, status.phase != .published,
              let bound = try await mutations.catalog.treeImportOperation(operationKey: plan.key),
              bound.operation.state == .completed,
              let root = try mutations.staging.load(status.key),
              let retained = root.treeImport, retained.layoutVersion == 2,
              retained.tree == status.tree else { throw CocoaError(.fileReadCorruptFile) }
        let snapshot = try LocalTreeSnapshot.load(retained.tree, in: mutations.staging)
        try qualify(plan, step: bound.step, intent: bound.operation.intent,
            parent: bound.parentIdentity, destinationParent: bound.destinationParentIdentity,
            status: status, snapshot: snapshot)
    }
}
