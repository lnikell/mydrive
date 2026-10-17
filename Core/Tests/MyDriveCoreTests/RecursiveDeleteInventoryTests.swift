import Testing
@testable import MyDriveCore

@Suite struct RecursiveDeleteInventoryTests {
    @Test func incompleteInventoryIsRefusedAndCompletedInventorySurvivesTombstoneAndRestart() async throws {
        let f = try Fixture(), entry = directory("package.rtfd", 1)
        try await publish([entry], to: f.catalog)
        let root = try #require(try await f.catalog.child(named: entry.name, in: Catalog.rootID))
        let status = try await f.catalog.prepareRecursiveDelete(intent: recursiveIntent(root), rootParentIdentity: identity(900))
        await #expect(throws: CatalogError.invalidTransition) {
            try await f.catalog.recursiveDeleteInventory(key: status.key)
        }
        let scan = try await f.catalog.beginScan(of: root.id)
        _ = try await f.catalog.captureDeleteDirectory(key: status.key, scan: scan, directory: root.entry)
        // Only nextWork can establish that no unfinished directory remains.
        await #expect(throws: CatalogError.invalidTransition) {
            try await f.catalog.recursiveDeleteInventory(key: status.key)
        }
        let work = try #require(try await f.catalog.nextRecursiveDeleteWork(key: status.key).first)
        #expect(try await f.catalog.recursiveDeleteInventory(key: status.key) == [root])
        let (id, childKey) = try await childOperation(work, in: f.catalog)
        try await f.catalog.recordRecursiveDeleteProgress(key: status.key,
            updates: [.bindOperation(itemID: id, key: childKey), .removed(itemID: id, key: childKey)])
        #expect(try await f.catalog.item(id: root.id)?.isDeleted == true)
        let reopened = try Catalog(databaseURL: f.url)
        let generation = try await reopened.generation(), anchor = try await reopened.currentChangeAnchor()
        #expect(try await reopened.recursiveDeleteInventory(key: status.key) == [root])
        #expect(try await reopened.recursiveDeleteInventory(key: status.key, afterID: root.id).isEmpty)
        #expect(try await reopened.generation() == generation)
        #expect(try await reopened.currentChangeAnchor() == anchor)
        #expect(try await reopened.operation(key: status.key)?.state == .completed)
    }

    @Test func keysetIncludesRemovedNodesAndFrozenVersionsAfterLiveTreeReplacement() async throws {
        let f = try Fixture(), rootEntry = directory("tree", 1)
        try await publish([rootEntry], to: f.catalog)
        let root = try #require(try await f.catalog.child(named: "tree", in: Catalog.rootID))
        var entries = (0..<273).map { file("file-\($0)", UInt64($0 + 10)) }
        entries.append(file("\u{00e9}", 400)); entries.append(file("e\u{0301}", 401))
        let status = try await f.catalog.prepareRecursiveDelete(intent: recursiveIntent(root), rootParentIdentity: identity(900))
        let scan = try await f.catalog.beginScan(of: root.id)
        try await f.catalog.stage(entries, in: scan)
        _ = try await f.catalog.captureDeleteDirectory(key: status.key, scan: scan, directory: root.entry)
        let first = try #require(try await f.catalog.nextRecursiveDeleteWork(key: status.key, limit: 1).first)
        let frozen = try await f.catalog.recursiveDeleteInventory(key: status.key, limit: 1_000)
        #expect(frozen.count == 276)
        let (id, childKey) = try await childOperation(first, in: f.catalog)
        try await f.catalog.recordRecursiveDeleteProgress(key: status.key,
            updates: [.bindOperation(itemID: id, key: childKey), .removed(itemID: id, key: childKey)])
        // Replace the live root and its children; the old selection's inventory
        // remains the original metadata, not the replacement or live tombstones.
        try await publish([directory("tree", 999)], to: f.catalog)
        let replacement = try #require(try await f.catalog.child(named: "tree", in: Catalog.rootID))
        #expect(replacement.id != root.id)
        try await publish([file("new", 1_000)], to: f.catalog, parent: replacement.id)
        let reopened = try Catalog(databaseURL: f.url)
        let generation = try await reopened.generation(), anchor = try await reopened.currentChangeAnchor()
        var seen: [CatalogItem] = [], after: String?
        while true {
            let page = try await reopened.recursiveDeleteInventory(key: status.key, afterID: after, limit: 17)
            #expect(page.count <= 17)
            if page.isEmpty { break }
            seen.append(contentsOf: page)
            after = page.last?.id
        }
        #expect(seen == frozen)
        #expect(Set(seen.map(\.id)).count == frozen.count)
        #expect(seen.allSatisfy { !$0.isDeleted })
        #expect(seen.contains { $0.id == id })
        #expect(!seen.contains { $0.id == replacement.id || $0.entry.name == "new" })
        #expect(try await reopened.generation() == generation)
        #expect(try await reopened.currentChangeAnchor() == anchor)
    }

    @Test func invalidLimitsCursorsAndUnknownManifestsFailWithoutPublishing() async throws {
        let f = try Fixture(), key = mutationUUID()
        let generation = try await f.catalog.generation()
        for limit in [0, -1, 1_001] {
            await #expect(throws: CatalogError.invalidPageSize) {
                try await f.catalog.recursiveDeleteInventory(key: key, limit: limit)
            }
        }
        for cursor in ["", "bad\0cursor", String(repeating: "x", count: 4_097)] {
            await #expect(throws: CatalogError.invalidEntry) {
                try await f.catalog.recursiveDeleteInventory(key: key, afterID: cursor)
            }
        }
        await #expect(throws: CatalogError.invalidTransition) {
            try await f.catalog.recursiveDeleteInventory(key: key)
        }
        #expect(try await f.catalog.generation() == generation)
    }

    private func identity(_ value: UInt64) -> RemoteObjectIdentity { .init(indexNumber: value, createdFiletime: value + 1) }
    private func directory(_ name: String, _ value: UInt64) -> RemoteEntry {
        RemoteEntry(name: name, kind: .directory, contentVersion: "directory-\(value)", metadataVersion: "metadata-\(value)",
                    objectIdentity: identity(value))
    }
    private func file(_ name: String, _ value: UInt64) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, contentVersion: "file-\(value)", metadataVersion: "metadata-\(value)", size: 42,
                    objectIdentity: identity(value))
    }
    private func publish(_ entries: [RemoteEntry], to catalog: Catalog, parent: String = Catalog.rootID) async throws {
        let scan = try await catalog.beginScan(of: parent)
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
