import Foundation
import MyDriveCore

// The standalone CLT Testing framework omits the Foundation cross-import
// overlay. Keep Foundation construction separate from the Testing source.
typealias MutationTestKey = UUID

func mutationUUID() -> UUID { UUID() }

func clockData(_ value: UInt8, count: Int = 1) -> Data { Data(repeating: value, count: count) }

func recursiveIntent(_ root: CatalogItem, context: CatalogDomainVersionState? = nil) -> JournalIntent {
    JournalIntent(itemID: root.id, expectedVersion: root.entry.contentVersion, action: .deleteTree,
                  expectedMetadataVersion: root.entry.metadataVersion, sourcePath: root.entry.name,
                  baseEntry: root.entry, deletionContextID: context?.contextID.uuidString.lowercased())
}

/// No network work is simulated here. The Core API explicitly receives a
/// verified outcome from its owner; these helpers prepare the real child journal
/// and exercise the same atomic publication path that the callback will use.
func childOperation(_ work: RecursiveDeleteWork, in catalog: Catalog) async throws -> (String, UUID) {
    guard case .remove(let item, let path, _, let key, _) = work else { throw CatalogError.invalidEntry }
    let intent = JournalIntent(idempotencyKey: key, itemID: item.id,
        expectedVersion: item.entry.contentVersion, action: .delete,
        expectedMetadataVersion: item.entry.metadataVersion, sourcePath: path, baseEntry: item.entry)
    let operation = try await catalog.enqueue(intent)
    if operation.state == .queued {
        try await catalog.transitionOperation(key: operation.intent.idempotencyKey, from: .queued, to: .executing)
    }
    return (item.id, operation.intent.idempotencyKey)
}
