import Testing
@testable import MyDriveCore

@Suite struct RecursiveDeleteTests {
    @Test func incompleteListingNeverBecomesDeleteWorkAndRestartRecapturesOnlyUnfinishedDirectory() async throws {
        let f = try Fixture()
        let root = try await seed(f.catalog)
        let original = try await f.catalog.children(of: root.id).items
        let intent = recursiveIntent(root)
        let status = try await f.catalog.prepareRecursiveDelete(intent: intent, rootParentIdentity: shareIdentity)
        let incomplete = try await f.catalog.beginScan(of: root.id)
        try await f.catalog.stage([file("first", 2)], in: incomplete)
        #expect(try await f.catalog.nextRecursiveDeleteWork(key: status.key).count == 1)
        #expect(try await f.catalog.children(of: root.id).items == original)
        let reopened = try Catalog(databaseURL: f.url)
        let restarted = try await reopened.beginScan(of: root.id)
        try await reopened.stage([file("first", 2), file("second", 3)], in: restarted)
        let captured = try await reopened.captureDeleteDirectory(key: status.key, scan: restarted, directory: root.entry)
        #expect(captured.totalNodes == 3)
        let work = try await reopened.nextRecursiveDeleteWork(key: status.key)
        #expect(work.count == 2)
        for value in work { if case .capture = value { Issue.record("Incomplete frontier leaked past freeze") } }
        await #expect(throws: CatalogError.invalidTransition) {
            try await reopened.captureDeleteDirectory(key: status.key, scan: incomplete, directory: root.entry)
        }
    }

    @Test func replacedParentOrUnsupportedChildCannotFreezeOrPublishAPartialInventory() async throws {
        let f = try Fixture()
        let root = try await seed(f.catalog)
        let status = try await f.catalog.prepareRecursiveDelete(intent: recursiveIntent(root), rootParentIdentity: shareIdentity)
        let generation = try await f.catalog.generation()
        let scan = try await f.catalog.beginScan(of: root.id)
        try await f.catalog.stage([file("new", 4)], in: scan)
        await #expect(throws: CatalogError.invalidParent) {
            _ = try await f.catalog.captureDeleteDirectory(key: status.key, scan: scan,
                directory: self.directory("tree", 99))
        }
        #expect(try await f.catalog.generation() == generation)
        #expect(try await f.catalog.child(named: "new", in: root.id) == nil)
        let unsupported = try await f.catalog.beginScan(of: root.id)
        try await f.catalog.stage([RemoteEntry(name: "link", kind: .symbolicLink, contentVersion: "v", metadataVersion: "m")], in: unsupported)
        await #expect(throws: CatalogError.invalidEntry) {
            _ = try await f.catalog.captureDeleteDirectory(key: status.key, scan: unsupported, directory: root.entry)
        }
        #expect(try await f.catalog.nextRecursiveDeleteWork(key: status.key).count == 1)
    }

    @Test func postorderProgressIsAtomicDurableAndDoesNotAdoptNewChildren() async throws {
        let f = try Fixture()
        let catalog = try Catalog(databaseURL: f.url, initialDomainVersionArchive: clockData(0))
        let root = try await seed(catalog)
        let intent = recursiveIntent(root, context: catalog.initialDomainVersionState)
        let status = try await catalog.prepareRecursiveDelete(intent: intent, rootParentIdentity: shareIdentity)
        try await capture(root, entries: [file("first", 2), file("second", 3)], key: status.key, in: catalog)
        let work = try await catalog.nextRecursiveDeleteWork(key: status.key, limit: 1)
        let (id, childKey) = try await childOperation(try #require(work.first), in: catalog)
        let anchor = try await catalog.currentChangeAnchor()
        let partial = try await catalog.recordRecursiveDeleteProgress(key: status.key,
            updates: [.bindOperation(itemID: id, key: childKey), .removed(itemID: id, key: childKey)],
            advancingDomainVersion: .init(expectedEpoch: 0, nextArchive: clockData(1)))
        #expect(partial.removedNodes == 1)
        #expect(partial.phase == .frozen)
        #expect(partial.domainVersionState?.epoch == 1)
        #expect(try await catalog.operation(key: status.key)?.state == .executing)
        #expect(try await catalog.changes(since: anchor).deletedIDs == [id])
        #expect(try await catalog.mutationResult(key: childKey)?.tombstones == [id])
        let reopened = try Catalog(databaseURL: f.url, initialDomainVersionArchive: clockData(99))
        #expect(reopened.initialDomainVersionState?.epoch == 1)
        let remaining = try await reopened.children(of: root.id).items
        try await publish(remaining.map(\.entry) + [file("new-after-freeze", 100)], to: reopened, parent: root.id)
        let pending = try await reopened.nextRecursiveDeleteWork(key: status.key)
        #expect(pending.count == 1)
        if case .remove(let item, _, _, _, _) = try #require(pending.first) {
            #expect(item.entry.name != "new-after-freeze")
        }
        let replay = try await reopened.prepareRecursiveDelete(intent: recursiveIntent(root), rootParentIdentity: shareIdentity)
        #expect(replay.key == status.key)
        #expect(replay.totalNodes == 3)
        #expect(replay.removedNodes == 1)
        let duplicate = try await reopened.recordRecursiveDeleteProgress(key: status.key,
            updates: [.removed(itemID: id, key: childKey)],
            advancingDomainVersion: .init(expectedEpoch: 0, nextArchive: clockData(2)))
        #expect(duplicate.domainVersionState?.epoch == 1) // Replay does not advance clock.
    }

    @Test func parentCannotCompleteBeforeChildrenAndClockFailureRollsBackEveryEffect() async throws {
        let f = try Fixture()
        let catalog = try Catalog(databaseURL: f.url, initialDomainVersionArchive: clockData(0))
        let root = try await seed(catalog)
        let status = try await catalog.prepareRecursiveDelete(intent: recursiveIntent(root), rootParentIdentity: shareIdentity)
        try await capture(root, entries: [file("first", 2), file("second", 3)], key: status.key, in: catalog)
        let work = try await catalog.nextRecursiveDeleteWork(key: status.key)
        let rootOperation = try await catalog.enqueue(JournalIntent(idempotencyKey: mutationUUID(), itemID: root.id,
            expectedVersion: root.entry.contentVersion, action: .delete, expectedMetadataVersion: root.entry.metadataVersion, sourcePath: root.entry.name, baseEntry: root.entry))
        try await catalog.transitionOperation(key: rootOperation.intent.idempotencyKey, from: .queued, to: .executing)
        await #expect(throws: CatalogError.invalidTransition) {
            try await catalog.recordRecursiveDeleteProgress(key: status.key, updates: [
                .bindOperation(itemID: root.id, key: rootOperation.intent.idempotencyKey),
                .removed(itemID: root.id, key: rootOperation.intent.idempotencyKey)])
        }
        let (id, childKey) = try await childOperation(try #require(work.first), in: catalog)
        let generation = try await catalog.generation()
        let anchor = try await catalog.currentChangeAnchor()
        await #expect(throws: CatalogError.invalidTransition) {
            try await catalog.recordRecursiveDeleteProgress(key: status.key,
                updates: [.bindOperation(itemID: id, key: childKey), .removed(itemID: id, key: childKey)],
                advancingDomainVersion: .init(expectedEpoch: 42, nextArchive: clockData(1)))
        }
        #expect(try await catalog.item(id: id)?.isDeleted == false)
        #expect(try await catalog.generation() == generation)
        #expect(try await catalog.currentChangeAnchor() == anchor)
        #expect(try await catalog.mutationResult(key: childKey) == nil)
        #expect(try await catalog.domainVersionState()?.epoch == 0)
    }

    @Test func anObjectMovedOutsideTheFrozenNamespaceIsNeverRetiredByItsOldPath() async throws {
        let f = try Fixture()
        let root = try await seed(f.catalog)
        let status = try await f.catalog.prepareRecursiveDelete(intent: recursiveIntent(root), rootParentIdentity: shareIdentity)
        try await capture(root, entries: [file("first", 2), file("second", 3)], key: status.key, in: f.catalog)
        let work = try await f.catalog.nextRecursiveDeleteWork(key: status.key)
        let moved = try #require(try await f.catalog.child(named: "first", in: root.id))
        let move = JournalIntent(itemID: moved.id, expectedVersion: moved.entry.contentVersion,
            action: .move(parentID: Catalog.rootID, name: moved.entry.name))
        _ = try await f.catalog.enqueue(move)
        try await f.catalog.transitionOperation(key: move.idempotencyKey, from: .queued, to: .executing)
        try await f.catalog.commitMutation(key: move.idempotencyKey,
            upserts: [.init(id: moved.id, parentID: Catalog.rootID, entry: moved.entry)], tombstones: [])
        for value in work {
            let (id, childKey) = try await childOperation(value, in: f.catalog)
            try await f.catalog.recordRecursiveDeleteProgress(key: status.key,
                updates: [.bindOperation(itemID: id, key: childKey), .removed(itemID: id, key: childKey)])
        }
        let rootWork = try #require(try await f.catalog.nextRecursiveDeleteWork(key: status.key).first)
        let (rootID, childKey) = try await childOperation(rootWork, in: f.catalog)
        let result = try await f.catalog.recordRecursiveDeleteProgress(key: status.key,
            updates: [.bindOperation(itemID: rootID, key: childKey), .removed(itemID: rootID, key: childKey)])
        #expect(result.phase == .completed)
        #expect(result.removedNodes == 3)
        #expect(try await f.catalog.item(id: moved.id)?.isDeleted == false)
        #expect(try await f.catalog.relativePath(id: moved.id) == "first")
        #expect(try await f.catalog.operation(key: status.key)?.state == .completed)
        #expect(try await f.catalog.mutationResult(key: status.key)?.tombstones == [root.id])
        let replay = try await f.catalog.recordRecursiveDeleteProgress(key: status.key,
            updates: [.bindOperation(itemID: rootID, key: childKey), .removed(itemID: rootID, key: childKey)])
        #expect(replay.phase == .completed)
        #expect(replay.removedNodes == 3)
    }

    private var shareIdentity: RemoteObjectIdentity { .init(indexNumber: 900, createdFiletime: 901) }
    private func file(_ name: String, _ id: UInt64) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, contentVersion: "opaque-\(id)", metadataVersion: "metadata-\(id)", size: 42,
                    objectIdentity: .init(indexNumber: id, createdFiletime: id + 1))
    }
    private func directory(_ name: String, _ id: UInt64) -> RemoteEntry {
        RemoteEntry(name: name, kind: .directory, contentVersion: "directory-\(id)", metadataVersion: "meta-\(id)",
                    objectIdentity: .init(indexNumber: id, createdFiletime: id + 1))
    }
    private func seed(_ catalog: Catalog) async throws -> CatalogItem {
        try await publish([directory("tree", 1)], to: catalog)
        let root = try #require(try await catalog.child(named: "tree", in: Catalog.rootID))
        try await publish([file("first", 2), file("second", 3)], to: catalog, parent: root.id)
        return root
    }
    private func publish(_ entries: [RemoteEntry], to catalog: Catalog, parent: String = Catalog.rootID) async throws {
        let scan = try await catalog.beginScan(of: parent)
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
    private func capture(_ item: CatalogItem, entries: [RemoteEntry], key: MutationTestKey, in catalog: Catalog) async throws {
        let scan = try await catalog.beginScan(of: item.id)
        try await catalog.stage(entries, in: scan)
        _ = try await catalog.captureDeleteDirectory(key: key, scan: scan, directory: item.entry)
    }
}
