import Foundation
import MyDriveCore

enum TreeTransferEvent: Sendable {
    case started(id: UUID, itemID: String, path: String, bytes: Int64, progress: Progress)
    case finished(id: UUID, error: (any Error)?)
}

extension ProviderTreeImport {
    func uploadFile(step: TreeImportStep, intent: JournalIntent, parent: RemoteObjectIdentity,
                    destinationParent: RemoteObjectIdentity?, status: TreeImportStatus,
                    snapshot: LocalTreeSnapshot, progress: TreeWorkProgress) async throws -> TreeImportStatus {
        guard let payload = intent.payload,
              let file = try await mutations.catalog.treeImportEntry(key: status.key, itemID: intent.itemID),
              file.kind == .file else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = Progress(totalUnitCount: max(1, payload.size))
        let transfer = ContentFetchProgress(bytes, expectedBytes: payload.size)
        let path = ProviderMutations.join(status.destinationPath, file.path)
        await mutations.transferActivity(.started(id: intent.idempotencyKey, itemID: intent.itemID,
                                                   path: path, bytes: payload.size, progress: bytes))
        do {
            let result = try await performMutation(step: step, intent: intent, parent: parent,
                destinationParent: destinationParent, status: status, snapshot: snapshot,
                progress: progress.observing { transfer.received($0) })
            transfer.finish {}
            await mutations.transferActivity(.finished(id: intent.idempotencyKey, error: nil))
            return result
        } catch {
            await mutations.transferActivity(.finished(id: intent.idempotencyKey, error: error))
            throw error
        }
    }
}
