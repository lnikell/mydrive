import Testing
@testable import MyDriveCore

@Suite struct FirstVisibilityTests {
    private var heldRoot: RemoteEntry { directory("", 900) }

    @Test func prefixCommitsBeforeEOFOnceAndTerminalReusesCanonicalIDs() async throws {
        let f = try Fixture(), root = try await f.catalog.item(id: Catalog.rootID)
        let scan = try await f.catalog.beginScan(), generation = try await f.catalog.generation()
        let entries = (0..<140).map { file("n" + String(1_000 + $0), UInt64($0 + 1)) }
        #expect(try await f.catalog.stageVisibleAdditions(entries, in: scan, directory: heldRoot))
        let prefix = try await f.catalog.children(limit: 1_000).items
        #expect(prefix.count == 128)
        #expect(try await f.catalog.generation() == generation + 1)
        #expect(try await f.catalog.hasPublishedChildren())
        #expect(try await !f.catalog.hasCompletedScan(of: Catalog.rootID))
        #expect(try await f.catalog.connectionState() == .unknown)
        #expect(try await f.catalog.item(id: Catalog.rootID) == root)
        #expect(try await !f.catalog.stageVisibleAdditions([file("later", 500)], in: scan, directory: heldRoot))
        #expect(try await f.catalog.children(limit: 1_000).items == prefix)
        try await f.catalog.completeScan(scan, directory: heldRoot)
        let completed = try await f.catalog.children(limit: 1_000).items
        #expect(completed.count == 141 && completed.filter { $0.entry.name.hasPrefix("n") }.prefix(128).map(\.id) == prefix.map(\.id))
        #expect(try await f.catalog.hasCompletedScan(of: Catalog.rootID))
        #expect(try await f.catalog.item(id: Catalog.rootID) == root)
    }

    @Test func normalPaginationAndGenerationExpiryApplyToVisiblePrefix() async throws {
        let f = try Fixture(), scan = try await f.catalog.beginScan()
        let entries = (0..<130).map { file("n" + String(1_000 + $0), UInt64($0 + 1)) }
        #expect(try await f.catalog.stageVisibleAdditions(entries, in: scan, directory: heldRoot))
        for size in [1, 32, 128] {
            var cursor: ListingCursor?, ids: [String] = []
            repeat {
                let page = try await f.catalog.children(after: cursor, limit: size)
                ids += page.items.map(\.id); cursor = page.nextCursor
            } while cursor != nil
            #expect(ids.count == 128 && Set(ids).count == 128)
        }
        let cursor = try #require(try await f.catalog.children(limit: 32).nextCursor)
        try await f.catalog.completeScan(scan)
        await #expect(throws: CatalogError.staleCursor) { try await f.catalog.children(after: cursor) }
    }

    @Test func failureAndRestartKeepPositivesWithoutClaimingCompletenessOrAbsence() async throws {
        let f = try Fixture(), scan = try await f.catalog.beginScan(), early = file("early", 10)
        #expect(try await f.catalog.stageVisibleAdditions([early], in: scan, directory: heldRoot))
        let published = try #require(try await f.catalog.child(named: "early", in: Catalog.rootID))
        await #expect(throws: CatalogError.self) { try await f.catalog.stage([early], in: scan) }
        try await f.catalog.abandonScan(scan)
        let reopened = try Catalog(databaseURL: f.url)
        #expect(try await reopened.hasPublishedChildren())
        #expect(try await !reopened.hasCompletedScan(of: Catalog.rootID))
        #expect(try await reopened.child(named: "early", in: Catalog.rootID) == published)
        let retry = try await reopened.beginScan()
        #expect(try await !reopened.stageVisibleAdditions([file("later", 11)], in: retry, directory: heldRoot))
        #expect(try await reopened.children().items == [published])
        try await reopened.stage([early], in: retry)
        try await reopened.completeScan(retry)
        #expect(try await reopened.child(named: "early", in: Catalog.rootID)?.id == published.id)
        let empty = try await reopened.beginScan()
        #expect(try await !reopened.stageVisibleAdditions([], in: empty, directory: heldRoot))
        #expect(try await reopened.hasPublishedChildren())
        try await reopened.completeScan(empty)
        #expect(try await !reopened.hasPublishedChildren())
    }

    @Test func emptyAndAtomicCallersDoNotPublishBeforeSuccessfulCompletion() async throws {
        let f = try Fixture(), scan = try await f.catalog.beginScan()
        #expect(try await !f.catalog.stageVisibleAdditions([], in: scan, directory: heldRoot))
        #expect(try await !f.catalog.hasCompletedScan(of: Catalog.rootID))
        try await f.catalog.stage([file("atomic", 1)], in: scan)
        #expect(try await !f.catalog.hasPublishedChildren())
        try await f.catalog.completeScan(scan)
        #expect(try await f.catalog.hasPublishedChildren())
        let observed = try await f.catalog.beginScan()
        #expect(try await !f.catalog.stageVisibleAdditions([file("unpublished", 2)], in: observed, directory: heldRoot))
        #expect(try await f.catalog.child(named: "unpublished", in: Catalog.rootID) == nil)
    }

    @Test func prefixSQLFailureRollsBackStagingBindingsItemsFeedAndGeneration() async throws {
        let f = try Fixture(), scan = try await f.catalog.beginScan()
        let generation = try await f.catalog.generation(), anchor = try await f.catalog.currentChangeAnchor()
        try visibilitySQL(f, "CREATE TRIGGER fail_prefix BEFORE INSERT ON items WHEN NEW.name='bad' BEGIN SELECT RAISE(ABORT,'test'); END;")
        await #expect(throws: CatalogError.self) {
            try await f.catalog.stageVisibleAdditions([self.file("good", 1), self.file("bad", 2)], in: scan, directory: self.heldRoot)
        }
        #expect(try await !f.catalog.hasPublishedChildren())
        #expect(try await f.catalog.generation() == generation)
        #expect(try await f.catalog.currentChangeAnchor() == anchor)
        #expect(try visibilityQuery(f, "SELECT count(*) FROM scan_entries") == ["0"])
        #expect(try await f.catalog.stageVisibleAdditions([file("good", 1)], in: scan, directory: heldRoot))
    }

    @Test func existingTypedAliasesKeysAndUnknownKindsDeferWithoutAdoption() async throws {
        let f = try Fixture(), target = directory("target", 10), known = file("known", 20, key: "owned-key")
        let dead = file("dead", 21, key: "dead-key")
        try await publish([target, known, dead], to: f.catalog)
        let deadID = try #require(try await f.catalog.child(named: "dead", in: Catalog.rootID)?.id)
        try await publish([target, known], to: f.catalog)
        let parent = try #require(try await f.catalog.child(named: "target", in: Catalog.rootID))
        let scan = try await f.catalog.beginScan(of: parent.id)
        let candidates = [file("moved-key", 30, key: "owned-key"), file("alias", 20), file("retired-alias", 21),
                          RemoteEntry(name: "unknown", kind: .file, contentVersion: "v", metadataVersion: "m"),
                          RemoteEntry(name: "reparse", kind: .symbolicLink, contentVersion: "v", metadataVersion: "m", objectIdentity: .init(indexNumber: 31, createdFiletime: 32)),
                          file("fresh", 40)]
        #expect(try await f.catalog.stageVisibleAdditions(candidates, in: scan, directory: target))
        #expect(try await f.catalog.children(of: parent.id).items.map(\.entry.name) == ["fresh"])
        #expect(try await f.catalog.child(named: "known", in: Catalog.rootID)?.entry == known)
        #expect(try await f.catalog.item(id: deadID)?.isDeleted == true)
        try await f.catalog.abandonScan(scan)
    }

    @Test func wrongHeldParentAndMovedAncestryCannotPublish() async throws {
        let f = try Fixture(), target = directory("target", 10, key: "target-key")
        try await publish([target], to: f.catalog)
        let parent = try #require(try await f.catalog.child(named: "target", in: Catalog.rootID))
        let scan = try await f.catalog.beginScan(of: parent.id)
        for held in [directory("target", 99), directory("wrong-name", 10), file("target", 10)] {
            await #expect(throws: CatalogError.invalidParent) {
                try await f.catalog.stageVisibleAdditions([self.file("unpublished", 50)], in: scan, directory: held)
            }
        }
        try await publish([directory("renamed", 10, key: "target-key")], to: f.catalog)
        await #expect(throws: CatalogError.invalidParent) {
            try await f.catalog.stageVisibleAdditions([self.file("unpublished", 51)], in: scan, directory: target)
        }
        #expect(try await !f.catalog.hasPublishedChildren(of: parent.id))
    }

    @Test func pendingMutationDefersAndMutationCommitInvalidatesEarlyScan() async throws {
        let f = try Fixture(), target = directory("target", 10, key: "target-key")
        try await publish([target], to: f.catalog)
        let parent = try #require(try await f.catalog.child(named: "target", in: Catalog.rootID))
        let scan = try await f.catalog.beginScan(of: parent.id)
        let intent = JournalIntent(itemID: parent.id, expectedVersion: target.contentVersion, action: .rename(name: "renamed"),
            expectedMetadataVersion: target.metadataVersion, sourcePath: "target", destinationPath: "renamed", baseEntry: target)
        _ = try await f.catalog.enqueue(intent)
        #expect(try await !f.catalog.stageVisibleAdditions([file("pending", 41)], in: scan, directory: target))
        #expect(try await !f.catalog.hasPublishedChildren(of: parent.id))
        #expect(try await f.catalog.operation(key: intent.idempotencyKey)?.state == .queued)
        try await f.catalog.transitionOperation(key: intent.idempotencyKey, from: .queued, to: .executing)
        try await f.catalog.commitMutation(key: intent.idempotencyKey,
            upserts: [.init(id: parent.id, parentID: Catalog.rootID, entry: directory("renamed", 10, key: "target-key"))], tombstones: [])
        await #expect(throws: CatalogError.invalidScan) {
            try await f.catalog.stageVisibleAdditions([self.file("after-move", 42)], in: scan, directory: target)
        }
        let renamed = directory("renamed", 10, key: "target-key")
        let visibleScan = try await f.catalog.beginScan(of: parent.id)
        #expect(try await f.catalog.stageVisibleAdditions([file("early", 50)], in: visibleScan, directory: renamed))
        let early = try #require(try await f.catalog.child(named: "early", in: parent.id))
        let second = JournalIntent(itemID: parent.id, expectedVersion: renamed.contentVersion, action: .rename(name: "renamed2"),
            expectedMetadataVersion: renamed.metadataVersion, sourcePath: "renamed", destinationPath: "renamed2", baseEntry: renamed)
        _ = try await f.catalog.enqueue(second)
        try await f.catalog.transitionOperation(key: second.idempotencyKey, from: .queued, to: .executing)
        try await f.catalog.commitMutation(key: second.idempotencyKey,
            upserts: [.init(id: parent.id, parentID: Catalog.rootID, entry: directory("renamed2", 10, key: "target-key"))], tombstones: [])
        await #expect(throws: CatalogError.invalidScan) {
            try await f.catalog.stageVisibleAdditions([self.file("stale", 51)], in: visibleScan, directory: renamed)
        }
        #expect(try await f.catalog.relativePath(id: early.id) == "renamed2/early")
    }

    @Test func existingVersionEightDatabaseAddsIndexedAliasLookupWithoutChangingData() async throws {
        let f = try Fixture(), entry = file("kept", 101)
        try await publish([entry], to: f.catalog)
        let original = try await f.catalog.children().items, generation = try await f.catalog.generation()
        let anchor = try await f.catalog.currentChangeAnchor()
        try visibilitySQL(f, "ALTER TABLE observed_directories DROP COLUMN is_complete; PRAGMA user_version=8; DROP INDEX items_object_identity;")
        let reopened = try Catalog(databaseURL: f.url)
        #expect(try await reopened.children().items == original)
        #expect(try await reopened.generation() == generation)
        #expect(try await reopened.currentChangeAnchor() == anchor)
        #expect(try visibilityQuery(f, "PRAGMA user_version") == ["9"])
        let plan = try visibilityQuery(f, "EXPLAIN QUERY PLAN SELECT 1 FROM items WHERE object_index_number='101' AND object_created_filetime='102'", column: 3)
        #expect(plan.contains { $0.contains("items_object_identity") })
    }

    @Test func tombstonedSamePathNeverResurrectsThroughEarlyPublication() async throws {
        let f = try Fixture(), target = directory("target", 10)
        try await publish([target], to: f.catalog)
        let parent = try #require(try await f.catalog.child(named: "target", in: Catalog.rootID))
        let id = try await f.catalog.providerID(forCreateTemplate: "historical")
        let old = file("same", 70)
        let create = JournalIntent(itemID: id, expectedVersion: nil,
            action: .create(parentID: parent.id, name: old.name, kind: .file),
            payload: .init(id: mutationUUID(), size: old.size, sha256: String(repeating: "a", count: 64)),
            createTemplateID: "historical", destinationPath: "target/same")
        _ = try await f.catalog.enqueue(create)
        try await f.catalog.transitionOperation(key: create.idempotencyKey, from: .queued, to: .executing)
        try await f.catalog.commitMutation(key: create.idempotencyKey,
            upserts: [.init(id: id, parentID: parent.id, entry: old)], tombstones: [])
        let delete = JournalIntent(itemID: id, expectedVersion: old.contentVersion, action: .delete,
            expectedMetadataVersion: old.metadataVersion, sourcePath: "target/same", baseEntry: old)
        _ = try await f.catalog.enqueue(delete)
        try await f.catalog.transitionOperation(key: delete.idempotencyKey, from: .queued, to: .executing)
        try await f.catalog.commitMutation(key: delete.idempotencyKey, upserts: [], tombstones: [id])
        #expect(try await !f.catalog.hasCompletedScan(of: parent.id))
        let scan = try await f.catalog.beginScan(of: parent.id)
        #expect(try await f.catalog.stageVisibleAdditions([file("same", 71), file("fresh", 72)], in: scan, directory: target))
        #expect(try await f.catalog.children(of: parent.id).items.map(\.entry.name) == ["fresh"])
        #expect(try await f.catalog.item(id: id)?.isDeleted == true)
        try await f.catalog.completeScan(scan, directory: target)
        #expect(try await f.catalog.child(named: "same", in: parent.id)?.id != id)
    }

    @Test func byteDistinctUnicodeNamesHaveSeparateCanonicalBindings() async throws {
        let f = try Fixture(), scan = try await f.catalog.beginScan()
        let composed = "\u{00e9}.txt", decomposed = "e\u{0301}.txt"
        #expect(try await f.catalog.stageVisibleAdditions([file(composed, 1), file(decomposed, 2)], in: scan, directory: heldRoot))
        let first = try #require(try await f.catalog.child(named: composed, in: Catalog.rootID))
        let second = try #require(try await f.catalog.child(named: decomposed, in: Catalog.rootID))
        #expect(first.id != second.id)
        #expect(Array(first.entry.name.utf8) != Array(second.entry.name.utf8))
        try await f.catalog.completeScan(scan)
        #expect(try await f.catalog.child(named: composed, in: Catalog.rootID)?.id == first.id)
        #expect(try await f.catalog.child(named: decomposed, in: Catalog.rootID)?.id == second.id)
    }

    @Test func newPhysicalAliasesKeepDistinctPathIDsAndTerminalReusesBoth() async throws {
        let f = try Fixture(), scan = try await f.catalog.beginScan()
        // Existing Catalog identities are excluded from early adoption. Two
        // previously unknown physical aliases retain ordinary terminal semantics.
        #expect(try await f.catalog.stageVisibleAdditions([file("alias-a", 1), file("alias-b", 1)], in: scan, directory: heldRoot))
        let first = try #require(try await f.catalog.child(named: "alias-a", in: Catalog.rootID))
        let second = try #require(try await f.catalog.child(named: "alias-b", in: Catalog.rootID))
        #expect(first.id != second.id && first.entry.objectIdentity == second.entry.objectIdentity)
        try await f.catalog.completeScan(scan)
        #expect(try await f.catalog.child(named: "alias-a", in: Catalog.rootID)?.id == first.id)
        #expect(try await f.catalog.child(named: "alias-b", in: Catalog.rootID)?.id == second.id)
    }

    private func file(_ name: String, _ index: UInt64, key: String? = nil) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, remoteKey: key, contentVersion: "v", metadataVersion: "m", size: 12,
                    objectIdentity: .init(indexNumber: index, createdFiletime: index + 1))
    }
    private func directory(_ name: String, _ index: UInt64, key: String? = nil) -> RemoteEntry {
        RemoteEntry(name: name, kind: .directory, remoteKey: key, contentVersion: "v", metadataVersion: "m",
                    objectIdentity: .init(indexNumber: index, createdFiletime: index + 1))
    }
    private func publish(_ entries: [RemoteEntry], to catalog: Catalog) async throws {
        let scan = try await catalog.beginScan()
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
