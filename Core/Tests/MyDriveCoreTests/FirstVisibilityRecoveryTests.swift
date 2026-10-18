import Testing
@testable import MyDriveCore

@Suite struct FirstVisibilityRecoveryTests {
    @Test func failedNestedPrefixRemainsInExistingRefreshSetAfterRestartAndTerminalRepairsIt() async throws {
        let f = try Fixture(), target = directory("opened", 10), untouched = directory("unopened", 20)
        try await publish([target, untouched], to: f.catalog)
        let parent = try #require(try await f.catalog.child(named: target.name, in: Catalog.rootID))
        let scan = try await f.catalog.beginScan(of: parent.id), early = file("early", 30)
        #expect(try await f.catalog.stageVisibleAdditions([early], in: scan, directory: target))
        let published = try #require(try await f.catalog.child(named: early.name, in: parent.id))
        try await f.catalog.abandonScan(scan) // The adapter's terminal-helper failure path.
        let reopened = try Catalog(databaseURL: f.url)
        #expect(try await !reopened.hasCompletedScan(of: parent.id))
        #expect(try await reopened.hasPublishedChildren(of: parent.id))
        #expect(try await reopened.observedDirectories().map(\.id) == [parent.id])
        let retry = try await reopened.beginScan(of: parent.id)
        #expect(try await !reopened.stageVisibleAdditions([file("later", 31)], in: retry, directory: target))
        try await reopened.stage([early], in: retry)
        try await reopened.completeScan(retry, directory: target)
        #expect(try await reopened.hasCompletedScan(of: parent.id))
        #expect(try await reopened.child(named: early.name, in: parent.id)?.id == published.id)
        #expect(try await reopened.children(of: parent.id).items.count == 2)
        #expect(try await reopened.observedDirectories().map(\.id) == [parent.id])
    }

    @Test func completeAndIncompleteMembersShareBoundedRefreshPaginationWithoutUnopenedDirectories() async throws {
        let f = try Fixture()
        let directories = (0..<137).map { directory("d" + String(1_000 + $0), UInt64($0 + 1)) }
        try await publish(directories, to: f.catalog)
        let parents = try await f.catalog.children(limit: 1_000).items
        for (offset, parent) in parents.prefix(136).enumerated() {
            let scan = try await f.catalog.beginScan(of: parent.id)
            if offset.isMultiple(of: 2) { try await f.catalog.completeScan(scan) }
            else {
                #expect(try await f.catalog.stageVisibleAdditions([file("positive", UInt64(1_000 + offset))], in: scan, directory: parent.entry))
                try await f.catalog.abandonScan(scan)
                #expect(try await !f.catalog.hasCompletedScan(of: parent.id))
            }
        }
        let expected = Set(parents.prefix(136).map(\.id))
        for size in [1, 32, 128] {
            var afterID: String?, ids: [String] = []
            while true {
                let page = try await f.catalog.observedDirectories(afterID: afterID, limit: size)
                ids += page.map(\.id)
                guard page.count == size, let last = page.last else { break }
                afterID = last.id
            }
            #expect(ids.count == 136 && Set(ids) == expected)
        }
        let plan = try visibilityQuery(f, "EXPLAIN QUERY PLAN SELECT observed.item_id FROM observed_directories AS observed CROSS JOIN items ON items.id=observed.item_id WHERE observed.item_id>'a' AND items.kind='directory' AND items.is_deleted=0 ORDER BY observed.item_id LIMIT 128", column: 3)
        #expect(plan.first?.contains("sqlite_autoindex_observed_directories_1") == true)
        #expect(!plan.contains { $0.contains("TEMP B-TREE") })
    }

    @Test func actualVersionEightLayoutMigratesLegacyCompletedMembersWithoutDataChanges() async throws {
        let f = try Fixture(), entries = [directory("completed", 10), directory("unopened", 20)]
        try await publish(entries, to: f.catalog)
        let parent = try #require(try await f.catalog.child(named: "completed", in: Catalog.rootID))
        let completed = try await f.catalog.beginScan(of: parent.id)
        try await f.catalog.completeScan(completed)
        let items = try await f.catalog.children().items, generation = try await f.catalog.generation()
        let anchor = try await f.catalog.currentChangeAnchor()
        let originalMarkers = try visibilityQuery(f, "SELECT item_id FROM observed_directories ORDER BY item_id")
        try visibilitySQL(f, """
            ALTER TABLE observed_directories DROP COLUMN is_complete;
            DROP INDEX items_object_identity;
            DROP INDEX scan_assigned_items;
            PRAGMA user_version=8;
            """)
        #expect(try visibilityQuery(f, "PRAGMA table_info(observed_directories)", column: 1) == ["item_id"])
        let reopened = try Catalog(databaseURL: f.url)
        #expect(try visibilityQuery(f, "PRAGMA user_version") == ["9"])
        #expect(try visibilityQuery(f, "SELECT item_id FROM observed_directories WHERE is_complete=1 ORDER BY item_id") == originalMarkers)
        #expect(try await reopened.children().items == items)
        #expect(try await reopened.generation() == generation)
        #expect(try await reopened.currentChangeAnchor() == anchor)
        #expect(try await reopened.hasCompletedScan(of: parent.id))
        #expect(try await reopened.observedDirectories().map(\.id) == [parent.id])
    }

    @Test func incompleteMembershipFailureRollsBackItemsFeedBindingsAndGeneration() async throws {
        let f = try Fixture(), scan = try await f.catalog.beginScan()
        let generation = try await f.catalog.generation(), anchor = try await f.catalog.currentChangeAnchor()
        try visibilitySQL(f, "CREATE TRIGGER reject_partial BEFORE INSERT ON observed_directories WHEN NEW.is_complete=0 BEGIN SELECT RAISE(ABORT,'test'); END;")
        await #expect(throws: CatalogError.self) {
            try await f.catalog.stageVisibleAdditions([self.file("positive", 1)], in: scan, directory: self.directory("", 900))
        }
        #expect(try await !f.catalog.hasPublishedChildren())
        #expect(try await f.catalog.generation() == generation)
        #expect(try await f.catalog.currentChangeAnchor() == anchor)
        #expect(try visibilityQuery(f, "SELECT count(*) FROM scan_entries") == ["0"])
        #expect(try visibilityQuery(f, "SELECT count(*) FROM observed_directories") == ["0"])
    }

    private func file(_ name: String, _ index: UInt64) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, contentVersion: "v", metadataVersion: "m",
                    objectIdentity: .init(indexNumber: index, createdFiletime: index + 1))
    }
    private func directory(_ name: String, _ index: UInt64) -> RemoteEntry {
        RemoteEntry(name: name, kind: .directory, contentVersion: "v", metadataVersion: "m",
                    objectIdentity: .init(indexNumber: index, createdFiletime: index + 1))
    }
    private func publish(_ entries: [RemoteEntry], to catalog: Catalog) async throws {
        let scan = try await catalog.beginScan()
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
