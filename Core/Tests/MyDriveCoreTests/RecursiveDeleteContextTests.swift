import Testing
@testable import MyDriveCore

@Suite struct RecursiveDeleteContextTests {
    @Test func issuedContextSelectsItsOriginalScopeAndUnknownCallbackNeverSelectsAnExpandedScope() async throws {
        let f = try Fixture()
        let catalog = try Catalog(databaseURL: f.url, initialDomainVersionArchive: clockData(0))
        let root = try await seed(catalog)
        let v0 = try #require(catalog.initialDomainVersionState)
        let first = try await catalog.prepareRecursiveDelete(intent: recursiveIntent(root, context: v0),
            rootParentIdentity: parentIdentity, requestContext: clockData(42))
        let initialScan = try await catalog.beginScan(of: root.id)
        try await catalog.stage([file("first", 2)], in: initialScan)
        _ = try await catalog.captureDeleteDirectory(key: first.key, scan: initialScan, directory: root.entry)
        _ = try await catalog.nextRecursiveDeleteWork(key: first.key)
        let blocked = try await catalog.recordRecursiveDeleteProgress(key: first.key,
            updates: [.blocked(itemID: root.id, code: "directory_not_empty")],
            advancingDomainVersion: .init(expectedEpoch: 0, nextArchive: clockData(1)))
        let v1 = try #require(blocked.domainVersionState)
        let duplicate = try await catalog.recordRecursiveDeleteProgress(key: first.key,
            updates: [.blocked(itemID: root.id, code: "directory_not_empty")],
            advancingDomainVersion: .init(expectedEpoch: 0, nextArchive: clockData(9)))
        #expect(duplicate.domainVersionState?.epoch == 1)
        try await publish([file("first", 2), file("new", 3)], parent: root.id, in: catalog)
        let second = try await catalog.prepareRecursiveDelete(intent: recursiveIntent(root, context: v1),
            rootParentIdentity: parentIdentity, requestContext: clockData(43))
        #expect(second.key != first.key)
        let newScan = try await catalog.beginScan(of: root.id)
        try await catalog.stage([file("first", 2), file("new", 3)], in: newScan)
        _ = try await catalog.captureDeleteDirectory(key: second.key, scan: newScan, directory: root.entry)
        _ = try await catalog.nextRecursiveDeleteWork(key: second.key)
        #expect(try await catalog.prepareRecursiveDelete(intent: recursiveIntent(root), rootParentIdentity: parentIdentity).key == first.key)
        let old = try await catalog.prepareRecursiveDelete(intent: recursiveIntent(root, context: v0),
            rootParentIdentity: parentIdentity, requestContext: clockData(99))
        #expect(old.key == first.key)
        #expect(old.requestContext == clockData(42)) // Archive serialization does not establish authority.
        let unknown = JournalIntent(itemID: root.id, expectedVersion: root.entry.contentVersion, action: .deleteTree,
            sourcePath: "tree", baseEntry: root.entry, deletionContextID: mutationUUID().uuidString.lowercased())
        #expect(try await catalog.prepareRecursiveDelete(intent: unknown, rootParentIdentity: parentIdentity).key == first.key)
        #expect(try await catalog.prepareRecursiveDelete(intent: recursiveIntent(root, context: v1), rootParentIdentity: parentIdentity).key == second.key)
        let db = try SQLiteConnection(url: f.url, cacheKiB: 2_048)
        #expect(try db.scalarInt("SELECT total_nodes FROM recursive_deletes WHERE operation_key = ?", [.text(first.key.uuidString)]) == 2)
        #expect(try db.scalarInt("SELECT total_nodes FROM recursive_deletes WHERE operation_key = ?", [.text(second.key.uuidString)]) == 3)
        let reopened = try Catalog(databaseURL: f.url, initialDomainVersionArchive: clockData(99))
        #expect(reopened.initialDomainVersionState == v1)
        #expect(try await reopened.domainVersionState(epoch: 0) == v0)
        #expect(try await reopened.domainVersionState(epoch: 2) == nil)
    }

    @Test func exactUnicodeScopeAndChildBindingRejectCanonicalEquivalentPaths() async throws {
        let f = try Fixture()
        let root = try await seed(f.catalog)
        let intent = recursiveIntent(root)
        let first = try await f.catalog.prepareRecursiveDelete(intent: intent, rootParentIdentity: parentIdentity)
        let altered = JournalIntent(idempotencyKey: intent.idempotencyKey, itemID: root.id,
            expectedVersion: root.entry.contentVersion, action: .deleteTree,
            sourcePath: "tr\u{0065}\u{0301}e", baseEntry: root.entry)
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await f.catalog.prepareRecursiveDelete(intent: altered, rootParentIdentity: self.parentIdentity)
        }
        let scan = try await f.catalog.beginScan(of: root.id)
        try await f.catalog.stage([file("\u{00e9}", 2), file("e\u{0301}", 3)], in: scan)
        _ = try await f.catalog.captureDeleteDirectory(key: first.key, scan: scan, directory: root.entry)
        let work = try await f.catalog.nextRecursiveDeleteWork(key: first.key)
        #expect(work.count == 2)
        guard case .remove(let item, let path, _, _, _) = try #require(work.first) else { throw CatalogError.invalidEntry }
        let wrong = JournalIntent(itemID: item.id, expectedVersion: item.entry.contentVersion, action: .delete,
            sourcePath: path.hasSuffix("\u{00e9}") && path.utf8.count == 7 ? "tree/e\u{0301}" : "tree/\u{00e9}", baseEntry: item.entry)
        _ = try await f.catalog.enqueue(wrong)
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await f.catalog.recordRecursiveDeleteProgress(key: first.key,
                updates: [.bindOperation(itemID: item.id, key: wrong.idempotencyKey)])
        }
    }

    @Test func schemaFiveMigrationRetainsPendingScanAndJournalAndBoundsOpaqueClockArchives() async throws {
        let f = try Fixture()
        let root = try await seed(f.catalog)
        let intent = JournalIntent(itemID: root.id, expectedVersion: root.entry.contentVersion, action: .rename(name: "retained"))
        _ = try await f.catalog.enqueue(intent)
        let scan = try await f.catalog.beginScan(of: root.id)
        try await f.catalog.stage([file("pending", 2)], in: scan)
        let db = try SQLiteConnection(url: f.url, cacheKiB: 2_048)
        try db.script("DROP TABLE recursive_delete_nodes; DROP TABLE recursive_deletes; DROP TABLE domain_versions; PRAGMA user_version=5;")
        let migrated = try Catalog(databaseURL: f.url, initialDomainVersionArchive: clockData(0))
        #expect(try db.scalarInt("PRAGMA user_version") == 6)
        #expect(try await migrated.operation(key: intent.idempotencyKey)?.state == .queued)
        try await migrated.completeScan(scan)
        #expect(try await migrated.child(named: "pending", in: root.id) != nil)
        #expect(migrated.initialDomainVersionState?.epoch == 0)
        #expect(throws: CatalogError.invalidEntry) { try Catalog(databaseURL: f.url, initialDomainVersionArchive: clockData(1, count: 0)) }
        #expect(throws: CatalogError.invalidEntry) { try Catalog(databaseURL: f.url, initialDomainVersionArchive: clockData(1, count: 32_769)) }
    }

    private var parentIdentity: RemoteObjectIdentity { .init(indexNumber: 800, createdFiletime: 801) }
    private func file(_ name: String, _ id: UInt64) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, contentVersion: "v\(id)", metadataVersion: "m\(id)", size: 42,
                    objectIdentity: .init(indexNumber: id, createdFiletime: id + 1))
    }
    private func seed(_ catalog: Catalog) async throws -> CatalogItem {
        let root = RemoteEntry(name: "tree", kind: .directory, contentVersion: "v1", metadataVersion: "m1",
                               objectIdentity: .init(indexNumber: 1, createdFiletime: 2))
        try await publish([root], parent: Catalog.rootID, in: catalog)
        return try #require(try await catalog.child(named: "tree", in: Catalog.rootID))
    }
    private func publish(_ entries: [RemoteEntry], parent: String, in catalog: Catalog) async throws {
        let scan = try await catalog.beginScan(of: parent)
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
