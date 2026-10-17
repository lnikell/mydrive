import Testing
@testable import MyDriveCore

struct ChangeFeedTests {
    private func publish(_ catalog: Catalog, _ entries: [RemoteEntry], parent: String = Catalog.rootID) async throws {
        let scan = try await catalog.beginScan(of: parent)
        for offset in stride(from: 0, to: entries.count, by: 1000) {
            try await catalog.stage(Array(entries[offset..<min(offset + 1000, entries.count)]), in: scan)
        }
        try await catalog.completeScan(scan)
    }

    @Test func changesSurviveRestartAndUnchangedScansAdvanceNothing() async throws {
        let fixture = try Fixture()
        let file = RemoteEntry(name: "file.txt", kind: .file, contentVersion: "v1", metadataVersion: "m1")
        try await publish(fixture.catalog, [file])
        let page = try await fixture.catalog.changes(since: 0)
        #expect(page.updated.count == 1)
        #expect(page.deletedIDs.isEmpty && !page.moreComing)
        let reopened = try Catalog(databaseURL: fixture.url)
        #expect(try await reopened.currentChangeAnchor() == page.anchor)
        try await publish(reopened, [file])
        #expect(try await reopened.currentChangeAnchor() == page.anchor)
        #expect(try await reopened.changes(since: page.anchor).updated.isEmpty)
    }

    @Test func directoryMovesDeleteFromOldParentAndKeepWorkingSetIdentity() async throws {
        let fixture = try Fixture()
        let catalog = fixture.catalog
        try await publish(catalog, [RemoteEntry(name: "a", kind: .directory, remoteKey: "a", contentVersion: "1", metadataVersion: "1"),
                                    RemoteEntry(name: "b", kind: .directory, remoteKey: "b", contentVersion: "1", metadataVersion: "1")])
        let parents = try await catalog.children().items
        let a = try #require(parents.first { $0.entry.name == "a" })
        let b = try #require(parents.first { $0.entry.name == "b" })
        try await publish(catalog, [RemoteEntry(name: "file", kind: .file, remoteKey: "file", contentVersion: "1", metadataVersion: "1")], parent: a.id)
        let id = try #require(try await catalog.children(of: a.id).items.first).id
        let anchor = try await catalog.currentChangeAnchor()
        try await publish(catalog, [RemoteEntry(name: "moved", kind: .file, remoteKey: "file", contentVersion: "1", metadataVersion: "2")], parent: b.id)
        #expect(try await catalog.changes(since: anchor, in: a.id).deletedIDs == [id])
        #expect(try await catalog.changes(since: anchor, in: b.id).updated.map(\.id) == [id])
        #expect(try await catalog.changes(since: anchor).updated.map(\.id) == [id])
    }

    @Test func deletionAndPagingReachExactTerminalAnchor() async throws {
        let fixture = try Fixture()
        let catalog = fixture.catalog
        let entries = (0..<7).map { RemoteEntry(name: "file-\($0)", kind: .file, contentVersion: "1", metadataVersion: "1") }
        try await publish(catalog, entries)
        var anchor: Int64 = 0
        var seen = Set<String>()
        while true {
            let page = try await catalog.changes(since: anchor, limit: 2)
            #expect(page.updated.count <= 2)
            seen.formUnion(page.updated.map(\.id))
            #expect(page.anchor > anchor)
            anchor = page.anchor
            if !page.moreComing { break }
        }
        #expect(seen.count == 7)
        let one = try #require(seen.first)
        let individual = try await catalog.changes(since: 0, itemID: one, limit: 1)
        #expect(individual.updated.map(\.id) == [one])
        #expect(!individual.moreComing)
        #expect(individual.anchor == anchor)
        try await publish(catalog, [])
        let deletion = try await catalog.changes(since: anchor)
        #expect(Set(deletion.deletedIDs) == seen)
        #expect(deletion.updated.isEmpty)
        #expect(deletion.anchor == (try await catalog.currentChangeAnchor()))
    }

    @Test func inheritedOfflinePolicyPublishesKnownDescendants() async throws {
        let fixture = try Fixture()
        let catalog = fixture.catalog
        try await publish(catalog, [RemoteEntry(name: "folder", kind: .directory, contentVersion: "1", metadataVersion: "1")])
        let folder = try #require(try await catalog.children().items.first)
        try await publish(catalog, [RemoteEntry(name: "nested", kind: .file, contentVersion: "1", metadataVersion: "1")], parent: folder.id)
        let file = try #require(try await catalog.children(of: folder.id).items.first)
        let anchor = try await catalog.currentChangeAnchor()
        try await catalog.setOfflinePolicy(.keepAvailable, for: folder.id)
        #expect(Set(try await catalog.changes(since: anchor).updated.map(\.id)) == [folder.id, file.id])
        let selected = try await catalog.currentChangeAnchor()
        try await catalog.setOfflinePolicy(.keepAvailable, for: folder.id)
        #expect(try await catalog.currentChangeAnchor() == selected)
        try await catalog.clearOfflineSelections(in: folder.id)
        #expect(Set(try await catalog.changes(since: selected).updated.map(\.id)) == [folder.id, file.id])
    }

    @Test func interruptedOrFailedPublicationDoesNotLeakChanges() async throws {
        let fixture = try Fixture()
        let catalog = fixture.catalog
        let anchor = try await catalog.currentChangeAnchor()
        let scan = try await catalog.beginScan()
        try await catalog.stage([RemoteEntry(name: "uncommitted", kind: .file, contentVersion: "1", metadataVersion: "1")], in: scan)
        #expect(try await catalog.currentChangeAnchor() == anchor)
        try await catalog.abandonScan(scan)
        #expect(try await catalog.currentChangeAnchor() == anchor)
    }

    @Test func pruningExpiresOldAnchorsWithoutGrowingForever() async throws {
        let fixture = try Fixture()
        let catalog = fixture.catalog
        let entries = (0..<51024).map { RemoteEntry(name: "file-\($0)", kind: .file, contentVersion: "1", metadataVersion: "1") }
        try await publish(catalog, entries)
        await #expect(throws: ChangeFeedError.invalidAnchor) { try await catalog.changes(since: 0) }
        let database = try SQLiteConnection(url: fixture.url, cacheKiB: 256)
        #expect(try database.scalarInt("SELECT count(*) FROM catalog_changes") <= 51023)
        let floor = try database.scalarInt("SELECT floor FROM catalog_change_state")
        #expect(floor > 0)
        #expect(try await catalog.changes(since: floor, limit: 1).updated.count == 1)
        let current = try await catalog.currentChangeAnchor()
        await #expect(throws: ChangeFeedError.invalidAnchor) { try await catalog.changes(since: current + 1) }
    }
}
