import Testing
@testable import MyDriveCore

@Suite struct FirstVisibilityIndexTests {
    @Test func actualPrefixStatementsUseRowidRangeAndIndexedAssignedLatch() async throws {
        let f = try Fixture(), scan = try await f.catalog.beginScan()
        let assignment = Catalog.scannedIdentityAssignment(scan, visibleAfter: 5_000)
        let publication = Catalog.scannedPublication(scan, visibleAfter: 5_000)
        let assignmentPlan = try visibilityQuery(f, "EXPLAIN QUERY PLAN " + assignment.0, assignment.1, column: 3)
        #expect(assignmentPlan.contains { $0.contains("observed USING INTEGER PRIMARY KEY (rowid>?)") })
        #expect(assignmentPlan.contains { $0.contains("scan_entries USING INTEGER PRIMARY KEY (rowid=?)") })
        #expect(assignmentPlan.contains { $0.contains("items_object_identity") })
        let publicationPlan = try visibilityQuery(f, "EXPLAIN QUERY PLAN " + publication.0, publication.1, column: 3)
        #expect(publicationPlan.contains { $0.contains("scan_entries USING INTEGER PRIMARY KEY (rowid>?)") })
        let latchPlan = try visibilityQuery(f, "EXPLAIN QUERY PLAN " + Catalog.hasAssignedScanItemsSQL, [.text(scan.id)], column: 3)
        #expect(latchPlan.contains { $0.contains("scan_assigned_items") })
        // The remaining eligibility/parent lookups keep their preexisting
        // indexed shape; global unfinished-mutation and ancestry work remain.
        let childrenPlan = try visibilityQuery(f, "EXPLAIN QUERY PLAN SELECT EXISTS(SELECT 1 FROM items WHERE parent_id=? AND is_deleted=0)", [.text(Catalog.rootID)], column: 3)
        #expect(childrenPlan.contains { $0.contains("children") })
        let parentPlan = try visibilityQuery(f, "EXPLAIN QUERY PLAN SELECT id FROM items WHERE id=?", [.text(Catalog.rootID)], column: 3)
        #expect(parentPlan.contains { $0.contains("sqlite_autoindex_items_1") })
        print("LOCAL prefix assignment plan=\(assignmentPlan); publication plan=\(publicationPlan); latch plan=\(latchPlan)")
    }

    @Test func laterTypedBatchPublishesOnlyItsPrefixAfterFiveThousandDeferredRows() async throws {
        let f = try Fixture(), scan = try await f.catalog.beginScan()
        let held = RemoteEntry(name: "", kind: .directory, contentVersion: "v", metadataVersion: "m",
                               objectIdentity: .init(indexNumber: 900, createdFiletime: 901))
        for batch in 0..<5 {
            let deferred = (0..<1_000).map { RemoteEntry(name: "a\(batch)-\($0)", kind: .file, contentVersion: "v", metadataVersion: "m") }
            #expect(try await !f.catalog.stageVisibleAdditions(deferred, in: scan, directory: held))
        }
        let fresh: [RemoteEntry] = (0..<200).map { index in
            let name = "z" + String(1_000 + index)
            let identity = RemoteObjectIdentity(indexNumber: UInt64(index + 1), createdFiletime: UInt64(index + 2))
            return RemoteEntry(name: name, kind: .file, contentVersion: "v", metadataVersion: "m", objectIdentity: identity)
        }
        #expect(try await f.catalog.stageVisibleAdditions(fresh, in: scan, directory: held))
        let prefix = try await f.catalog.children(limit: 1_000).items
        #expect(prefix.count == 128 && prefix.allSatisfy { $0.entry.name.hasPrefix("z") })
        #expect(try visibilityQuery(f, "SELECT count(*) FROM scan_entries WHERE item_id IS NOT NULL") == ["128"])
        try visibilitySQL(f, """
            CREATE TABLE terminal_assignment_count(value INTEGER);
            CREATE TRIGGER record_terminal_assignments BEFORE DELETE ON scans BEGIN
                INSERT INTO terminal_assignment_count SELECT count(*) FROM scan_entries WHERE scan_id=OLD.id AND item_id IS NOT NULL;
            END;
            """)
        try await visibilityMeasuredComplete(f, scan)
        #expect(try visibilityQuery(f, "SELECT value FROM terminal_assignment_count") == ["5200"])
        #expect(try visibilityQuery(f, "SELECT count(*) FROM items WHERE parent_id='root' AND is_deleted=0") == ["5200"])
        #expect(try visibilityQuery(f, "SELECT count(*) FROM scan_entries") == ["0"])
        for item in prefix { #expect(try await f.catalog.item(id: item.id) == item) }
        #expect(try await f.catalog.hasCompletedScan(of: Catalog.rootID))
    }

    @Test func indexMigrationLocalCostOnSyntheticTenThousandExistingRows() async throws {
        let f = try Fixture()
        try visibilitySQL(f, """
            ALTER TABLE observed_directories DROP COLUMN is_complete; PRAGMA user_version=8; DROP INDEX items_object_identity;
            DROP INDEX scan_assigned_items;
            BEGIN IMMEDIATE;
            WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000)
            INSERT INTO items(id,parent_id,name,kind,content_version,metadata_version,size,object_index_number,object_created_filetime)
            SELECT 'old-'||x,'root','old-'||x,'file','v','m',0,CAST(x AS TEXT),CAST(x+1 AS TEXT) FROM n;
            COMMIT;
            """)
        let before = try visibilityQuery(f, "SELECT count(*) FROM items")
        let reopened = try visibilityMeasuredReopen(f)
        #expect(before == ["10001"])
        #expect(try visibilityQuery(f, "SELECT count(*) FROM items") == before)
        #expect(try await reopened.hasPublishedChildren())
        let plan = try visibilityQuery(f, "EXPLAIN QUERY PLAN SELECT 1 FROM items WHERE object_index_number='10000' AND object_created_filetime='10001'", column: 3)
        #expect(plan.contains { $0.contains("items_object_identity") })
        let assignedPlan = try visibilityQuery(f, "EXPLAIN QUERY PLAN " + Catalog.hasAssignedScanItemsSQL, [.text("missing")], column: 3)
        #expect(assignedPlan.contains { $0.contains("scan_assigned_items") })
    }
}
