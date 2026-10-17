import Testing
@testable import MyDriveCore

@Suite struct RecursiveDeleteChildTests {
    @Test func firstDirectoryAttemptMayUseFreshTimestampsWithoutChangingItsFrozenIdentity() async throws {
        let f = try Fixture()
        let (root, status, work) = try await frozen(f.catalog, empty: true)
        guard case .remove(let item, let path, _, let key, _) = work else { throw CatalogError.invalidEntry }
        let freshEntry = RemoteEntry(name: item.entry.name, kind: .directory, contentVersion: "after-child-removals",
                                     metadataVersion: "fresh-mtime", objectIdentity: item.entry.objectIdentity)
        let fresh = CatalogItem(id: item.id, parentID: item.parentID, entry: freshEntry)
        let intent = childIntent(fresh, path: path, key: key)
        let operation = try await f.catalog.enqueueRecursiveDeleteChild(key: status.key, itemID: root.id, intent: intent)
        #expect(operation.intent.baseEntry == freshEntry)
        guard case .remove(let frozenItem, _, _, _, _) = try #require(try await f.catalog.nextRecursiveDeleteWork(key: status.key).first) else {
            throw CatalogError.invalidEntry
        }
        #expect(frozenItem.entry.contentVersion == root.entry.contentVersion)
        #expect(frozenItem.entry.objectIdentity == freshEntry.objectIdentity)
    }

    @Test func retiredCapturedChildCanBeJournaledAndReplayedWithoutResurrection() async throws {
        let f = try Fixture()
        let (root, status, work) = try await frozen(f.catalog)
        guard case .remove(let item, let path, _, let key, _) = work else { throw CatalogError.invalidEntry }
        let refresh = try await f.catalog.beginScan(of: root.id)
        try await f.catalog.completeScan(refresh)
        #expect(try await f.catalog.item(id: item.id)?.isDeleted == true)
        let intent = childIntent(item, path: path, key: key)
        await #expect(throws: CatalogError.missingItem(item.id)) { try await f.catalog.enqueue(intent) }
        let operation = try await f.catalog.enqueueRecursiveDeleteChild(key: status.key, itemID: item.id, intent: intent)
        #expect(operation.state == .queued)
        #expect(try await f.catalog.item(id: item.id)?.isDeleted == true)
        try await f.catalog.transitionOperation(key: operation.intent.idempotencyKey, from: .queued, to: .executing)
        let reopened = try Catalog(databaseURL: f.url)
        try await reopened.recoverInterruptedOperations()
        let replay = try await reopened.enqueueRecursiveDeleteChild(key: status.key, itemID: item.id, intent: intent)
        #expect(replay.intent == operation.intent)
        #expect(replay.state == .uncertain)
        let progress = try await reopened.recordRecursiveDeleteProgress(key: status.key,
            updates: [.removed(itemID: item.id, key: replay.intent.idempotencyKey)])
        #expect(progress.removedNodes == 1)
        #expect(try await reopened.mutationResult(key: replay.intent.idempotencyKey)?.tombstones.isEmpty == true)
        #expect(try await reopened.item(id: item.id)?.isDeleted == true)
    }

    @Test func deduplicatedCanonicalKeyIsBoundInTheSameTransactionBeforeRpc() async throws {
        let f = try Fixture()
        let (_, status, work) = try await frozen(f.catalog)
        guard case .remove(let item, let path, _, _, _) = work else { throw CatalogError.invalidEntry }
        let ordinary = childIntent(item, path: path, key: mutationUUID())
        _ = try await f.catalog.enqueue(ordinary)
        let proposed = childIntent(item, path: path, key: mutationUUID())
        let canonical = try await f.catalog.enqueueRecursiveDeleteChild(key: status.key, itemID: item.id, intent: proposed)
        #expect(canonical.intent.idempotencyKey == ordinary.idempotencyKey)
        #expect(try await f.catalog.operation(key: proposed.idempotencyKey) == nil)
        let reopened = try Catalog(databaseURL: f.url)
        guard case .remove(_, _, _, let bound, _) = try #require(try await reopened.nextRecursiveDeleteWork(key: status.key).first) else {
            throw CatalogError.invalidEntry
        }
        #expect(bound == canonical.intent.idempotencyKey)
    }

    @Test func wrongFrozenScopeAndVersionFailBeforeEnqueueAndLeaveBindingUntouched() async throws {
        let f = try Fixture()
        let (_, status, work) = try await frozen(f.catalog)
        guard case .remove(let item, let path, _, let key, _) = work else { throw CatalogError.invalidEntry }
        let wrongPath = childIntent(item, path: "elsewhere/file", key: mutationUUID())
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await f.catalog.enqueueRecursiveDeleteChild(key: status.key, itemID: item.id, intent: wrongPath)
        }
        #expect(try await f.catalog.operation(key: wrongPath.idempotencyKey) == nil)
        let changedEntry = RemoteEntry(name: item.entry.name, kind: .file, contentVersion: "new-bytes", metadataVersion: "new-meta",
            size: item.entry.size, objectIdentity: item.entry.objectIdentity)
        let changed = CatalogItem(id: item.id, parentID: item.parentID, entry: changedEntry)
        let wrongVersion = childIntent(changed, path: path, key: mutationUUID())
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await f.catalog.enqueueRecursiveDeleteChild(key: status.key, itemID: item.id, intent: wrongVersion)
        }
        #expect(try await f.catalog.operation(key: wrongVersion.idempotencyKey) == nil)
        guard case .remove(_, _, _, let unchanged, _) = try #require(try await f.catalog.nextRecursiveDeleteWork(key: status.key).first) else {
            throw CatalogError.invalidEntry
        }
        #expect(unchanged == key)
    }

    @Test func failedRebindRollsBackNewJournalAndRetiredRootCanFinishItsOriginalScope() async throws {
        let f = try Fixture()
        let (root, status, work) = try await frozen(f.catalog, empty: true)
        guard case .remove(let item, let path, _, let key, _) = work else { throw CatalogError.invalidEntry }
        let first = childIntent(item, path: path, key: key)
        let operation = try await f.catalog.enqueueRecursiveDeleteChild(key: status.key, itemID: item.id, intent: first)
        try await f.catalog.transitionOperation(key: operation.intent.idempotencyKey, from: .queued, to: .executing)
        try await f.catalog.transitionOperation(key: operation.intent.idempotencyKey, from: .executing, to: .uncertain)
        let changedEntry = RemoteEntry(name: item.entry.name, kind: .directory, contentVersion: "fresh-mtime", metadataVersion: "fresh-meta",
            objectIdentity: item.entry.objectIdentity)
        let changed = CatalogItem(id: item.id, parentID: item.parentID, entry: changedEntry)
        let replacement = childIntent(changed, path: path, key: mutationUUID())
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await f.catalog.enqueueRecursiveDeleteChild(key: status.key, itemID: item.id, intent: replacement)
        }
        #expect(try await f.catalog.operation(key: replacement.idempotencyKey) == nil)
        let refresh = try await f.catalog.beginScan()
        try await f.catalog.completeScan(refresh)
        #expect(try await f.catalog.item(id: root.id)?.isDeleted == true)
        let resumed = try await f.catalog.enqueueRecursiveDeleteChild(key: status.key, itemID: item.id, intent: first)
        let completed = try await f.catalog.recordRecursiveDeleteProgress(key: status.key,
            updates: [.removed(itemID: item.id, key: resumed.intent.idempotencyKey)])
        #expect(completed.phase == .completed)
        #expect(try await f.catalog.operation(key: status.key)?.state == .completed)
        #expect(try await f.catalog.enqueueRecursiveDeleteChild(key: status.key, itemID: item.id, intent: first).state == .completed)
    }

    private func frozen(_ catalog: Catalog, empty: Bool = false) async throws -> (CatalogItem, RecursiveDeleteStatus, RecursiveDeleteWork) {
        let entry = RemoteEntry(name: "tree", kind: .directory, contentVersion: "root", metadataVersion: "root-meta",
                                objectIdentity: .init(indexNumber: 1, createdFiletime: 2))
        let rootScan = try await catalog.beginScan()
        try await catalog.stage([entry], in: rootScan)
        try await catalog.completeScan(rootScan)
        let root = try #require(try await catalog.child(named: "tree", in: Catalog.rootID))
        let status = try await catalog.prepareRecursiveDelete(intent: recursiveIntent(root),
            rootParentIdentity: .init(indexNumber: 800, createdFiletime: 801))
        let scan = try await catalog.beginScan(of: root.id)
        if !empty {
            try await catalog.stage([RemoteEntry(name: "file", kind: .file, contentVersion: "bytes", metadataVersion: "file-meta", size: 42,
                objectIdentity: .init(indexNumber: 3, createdFiletime: 4))], in: scan)
        }
        _ = try await catalog.captureDeleteDirectory(key: status.key, scan: scan, directory: entry)
        return (root, status, try #require(try await catalog.nextRecursiveDeleteWork(key: status.key).first))
    }

    private func childIntent(_ item: CatalogItem, path: String, key: MutationTestKey) -> JournalIntent {
        JournalIntent(idempotencyKey: key, itemID: item.id, expectedVersion: item.entry.contentVersion, action: .delete,
            expectedMetadataVersion: item.entry.metadataVersion, sourcePath: path, baseEntry: item.entry)
    }
}
