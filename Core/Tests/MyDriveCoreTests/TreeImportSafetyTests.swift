import Testing
@testable import MyDriveCore

@Suite struct TreeImportSafetyTests {
    @Test func digestIsByteExactUUIDIndependentAndRejectsUnsafePathsOrOrder() throws {
        let nfc = try importTreeReference([.init(path: "", kind: .directory), importFile("caf\u{e9}")])
        let nfd = try importTreeReference([.init(path: "", kind: .directory), importFile("cafe\u{301}")])
        #expect(nfc.sha256 != nfd.sha256)
        #expect(nfc.sha256 == (try importTreeReference([.init(path: "", kind: .directory), importFile("caf\u{e9}")])).sha256)
        for path in ["/absolute", "../outside", "a/../b", "a//b", "a\\b", ".", "file\0suffix"] {
            #expect(throws: (any Error).self) {
                try importTreeReference([.init(path: "", kind: .directory), importFile(path)])
            }
        }
        #expect(throws: CatalogError.invalidEntry) {
            try importTreeReference([.init(path: "", kind: .directory), importFile("z"), importFile("a")])
        }
        #expect(throws: CatalogError.invalidEntry) {
            try importTreeReference([.init(path: "", kind: .directory), importFile("a", size: .max), importFile("b", size: 1)])
        }
    }

    @Test func digestMismatchAndSealedNamespaceFailBeforeExecutableWork() async throws {
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("expected")])
        let status = try await trial.prepare()
        _ = try await trial.catalog.stageTreeImport(key: status.key, entries: [.init(path: "", kind: .directory), importFile("wrong")])
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await trial.catalog.stageTreeImport(key: status.key, entries: [], sealedDirectories: [""], isComplete: true)
        }
        #expect(try await trial.catalog.treeImportStatus(rootID: status.rootID)?.phase == .building)
        await #expect(throws: CatalogError.invalidTransition) { try await trial.catalog.nextTreeImportWork(key: status.key) }
        #expect(try await trial.catalog.knownItems().isEmpty)
        let other = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("expected")])
        let second = try await other.prepare()
        _ = try await other.catalog.stageTreeImport(key: second.key, entries: [.init(path: "", kind: .directory)], sealedDirectories: [""])
        await #expect(throws: CatalogError.invalidParent) {
            try await other.catalog.stageTreeImport(key: second.key, entries: [other.entries[1]])
        }
    }

    @Test func directoryVerificationRequiresEveryExactChildAndRestartsIncompleteListings() async throws {
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("a"), importFile("b")])
        let status = try await trial.freeze()
        _ = try await trial.placeAll()
        var work = try await trial.catalog.nextTreeImportWork(key: status.key)
        for item in work { _ = try await trial.apply(item) } // File verification.
        work = try await trial.catalog.nextTreeImportWork(key: status.key)
        guard case .verifyDirectory(let item, _, let firstScan) = try #require(work.first) else { throw CatalogError.invalidEntry }
        let children = trial.children(of: item.id)
        #expect(children.count == 2)
        _ = try await trial.catalog.recordTreeImportProgress(key: status.key,
            update: .directoryPage(itemID: item.id, scanID: firstScan, entries: [children[0]]))
        let terminal = try trial.directoryTerminal(item.id)
        await #expect(throws: CatalogError.invalidEntry) {
            try await trial.catalog.recordTreeImportProgress(key: status.key,
                update: .directoryComplete(itemID: item.id, scanID: firstScan, entry: terminal))
        }
        let reopened = try Catalog(databaseURL: trial.fixture.url)
        let next = try #require(try await reopened.nextTreeImportWork(key: status.key).first)
        guard case .verifyDirectory(_, _, let freshScan) = next else { throw CatalogError.invalidEntry }
        #expect(freshScan != firstScan)
        await #expect(throws: CatalogError.invalidTransition) {
            try await reopened.recordTreeImportProgress(key: status.key,
                update: .directoryPage(itemID: item.id, scanID: firstScan, entries: [children[1]]))
        }
        let changed = RemoteEntry(name: children[0].name, kind: .file, contentVersion: "changed", metadataVersion: "changed",
                                  size: 42, objectIdentity: children[0].objectIdentity)
        let extra = RemoteEntry(name: "unknown", kind: .file, contentVersion: "x", metadataVersion: "x", size: 42,
                                objectIdentity: .init(indexNumber: 999, createdFiletime: 1_000))
        for invalid in [[children[0], children[0]], [children[0], extra], [changed]] {
            await #expect(throws: CatalogError.invalidEntry) {
                try await reopened.recordTreeImportProgress(key: status.key,
                    update: .directoryPage(itemID: item.id, scanID: freshScan, entries: invalid))
            }
        }
        // Failed pages roll back their earlier valid rows, so the exact page
        // still succeeds after a duplicate/extra entry was rejected.
        _ = try await reopened.recordTreeImportProgress(key: status.key,
            update: .directoryPage(itemID: item.id, scanID: freshScan, entries: children))
        _ = try await reopened.recordTreeImportProgress(key: status.key,
            update: .directoryComplete(itemID: item.id, scanID: freshScan, entry: terminal))
        #expect(try await reopened.knownItems().isEmpty)
        let result = try await trial.finish(in: reopened)
        #expect(result.phase == .published)
    }

    @Test func unicodeEquivalentNamesRemainTwoDistinctManifestAndCatalogRows() async throws {
        // NFD precedes NFC in UTF-8 BINARY order; Swift String equality alone
        // would collapse these independently authorized namespace entries.
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("e\u{301}"), importFile("\u{e9}")])
        _ = try await trial.freeze()
        let status = try await trial.finish()
        let children = try await trial.catalog.children(of: status.rootID).items
        #expect(children.count == 2 && children[0].id != children[1].id)
        #expect(children[0].entry.name.utf8.elementsEqual("e\u{301}".utf8))
        #expect(children[1].entry.name.utf8.elementsEqual("\u{e9}".utf8))
    }

    @Test func schemaSixMigrationRetainsPendingScanJournalSelectionAndFeed() async throws {
        let fixture = try Fixture()
        let entry = RemoteEntry(name: "old", kind: .file, contentVersion: "old", metadataVersion: "old", size: 42)
        let scan = try await fixture.catalog.beginScan()
        try await fixture.catalog.stage([entry], in: scan)
        try await fixture.catalog.completeScan(scan)
        let item = try #require(try await fixture.catalog.child(named: "old", in: Catalog.rootID))
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: item.id)
        let intent = JournalIntent(itemID: item.id, expectedVersion: "old", action: .rename(name: "later"))
        _ = try await fixture.catalog.enqueue(intent)
        let pending = try await fixture.catalog.beginScan()
        try await fixture.catalog.stage([entry], in: pending)
        let anchor = try await fixture.catalog.currentChangeAnchor(), generation = try await fixture.catalog.generation()
        let db = try SQLiteConnection(url: fixture.url, cacheKiB: 2_048)
        try db.script("DROP TABLE tree_import_operations; DROP TABLE tree_import_nodes; DROP TABLE tree_imports; PRAGMA user_version=6;")
        let migrated = try Catalog(databaseURL: fixture.url)
        #expect(try db.scalarInt("PRAGMA user_version") == 8)
        #expect(try await migrated.currentChangeAnchor() == anchor)
        #expect(try await migrated.generation() == generation)
        #expect(try await migrated.operation(key: intent.idempotencyKey)?.intent.requestFingerprint == intent.requestFingerprint)
        #expect(try await migrated.offlinePolicy(for: item.id) == .keepAvailable)
        try await migrated.completeScan(pending)
        #expect(try await migrated.item(id: item.id)?.isDeleted == false)
        #expect(try await migrated.treeImportStatus(rootID: item.id) == nil)
    }
}
