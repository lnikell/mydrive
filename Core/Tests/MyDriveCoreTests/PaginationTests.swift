import Testing
@testable import MyDriveCore

@Suite struct PaginationTests {
    @Test func directoryPagesPreserveBinaryNamesAcrossRestart() async throws {
        let fixture = try Fixture()
        let names = ["z", "A", "a", "--option", "caf\u{e9}", "cafe\u{301}", "🙂", "中"]
        try await publish(names.map { file($0) }, to: fixture.catalog)
        var page = try await fixture.catalog.children(limit: 1)
        var bytes = page.items.map { Array($0.entry.name.utf8) }
        let reopened = try Catalog(databaseURL: fixture.url)
        while let cursor = page.nextCursor {
            page = try await reopened.children(after: cursor, limit: 1)
            #expect(page.items.count == 1)
            bytes += page.items.map { Array($0.entry.name.utf8) }
        }
        let expected = names.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        #expect(bytes == expected)
    }

    @Test func liveItemAndSelectionPagesSkipRootAndDeletedItemsAsAppropriate() async throws {
        let fixture = try Fixture()
        let entries = (0..<13).map { file("file-\($0)", key: "key-\($0)") }
        try await publish(entries, to: fixture.catalog)
        let original = try await fixture.catalog.children(limit: 100).items
        for item in original { try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: item.id) }
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: Catalog.rootID)
        try await publish(Array(entries.dropFirst()), to: fixture.catalog)
        let expected = try await fixture.catalog.children(limit: 100).items.map(\.id).sorted()
        let reopened = try Catalog(databaseURL: fixture.url)
        var known: [String] = []
        var selected: [String] = []
        while true {
            let page = try await reopened.knownItems(afterID: known.last, limit: 2)
            guard !page.isEmpty else { break }
            #expect(page.count <= 2)
            known += page.map(\.id)
        }
        while true {
            let page = try await reopened.offlineSelections(afterID: selected.last, limit: 3)
            guard !page.isEmpty else { break }
            #expect(page.count <= 3)
            selected += page.map(\.id)
        }
        #expect(known == expected)
        #expect(selected == (expected + [Catalog.rootID]).sorted())
        #expect(try await reopened.knownItems(afterID: "zzzz", limit: 1).isEmpty)
        #expect(try await reopened.offlineSelections(afterID: "zzzz", limit: 1).isEmpty)
    }

    private func file(_ name: String, key: String? = nil) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, remoteKey: key, contentVersion: "v1", metadataVersion: "m1")
    }

    private func publish(_ entries: [RemoteEntry], to catalog: Catalog) async throws {
        let scan = try await catalog.beginScan()
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
