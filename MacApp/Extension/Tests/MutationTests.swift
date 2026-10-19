import FileProvider
import Foundation
import MyDriveCore

enum MutationTests {
    static func fixture(_ root: URL, _ peer: MutationPeer, check: (@Sendable () async throws -> Void)? = nil,
                        prepared: @escaping @Sendable (String, String?, Int64?) async -> Void = { _, _, _ in }) throws -> ProviderMutations {
        ProviderMutations(catalog: try Catalog(databaseURL: root.appendingPathComponent("catalog.sqlite")),
            staging: try MutationStaging(root: root.appendingPathComponent("Mutations")),
            remote: MutationRemote(stat: { await peer.stat($0) }, mutate: { try await peer.mutate($0, $1, $2) }),
            checkActive: check ?? { try Task.checkCancellation() }, preparedTransfer: prepared)
    }

    static func run() async throws -> Int {
        var count = 0
        count += try await creationReplay()
        count += try await allocatedResume()
        count += try await allocatedCancellation()
        count += try await lostAllocationReply()
        count += try await allocationBudget()
        count += try await preparedCancellation()
        count += try await staleContentConflict()
        count += try await atomicSaveConflict()
        count += try await unicodeRename()
        count += try await caseAliasRename()
        count += try await conflictFilenameBound()
        count += try await nonemptyRefusal()
        count += try await renameReplay()
        count += try await compoundRenameAndMetadataRetry()
        count += try await permanentCleanup()
        count += try await postCommitCancellation()
        count += try await postCommitCleanup()
        count += try await unsafeArchive()
        count += try await parentIdentity()
        count += try await legacyParent()
        count += try await parentReplacementAndUnsafeRecord()
        count += try await cleanupParent()
        count += try await conflictParent()
        count += try await unsupportedForkAndBoundedPlans()
        count += try await unexpectedDirectoryContents()
        count += try await wrongPurposeRecoveryPlan()
        return count
    }
}
