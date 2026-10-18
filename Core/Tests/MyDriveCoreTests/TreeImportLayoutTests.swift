import Testing
@testable import MyDriveCore

@Suite struct TreeImportLayoutTests {
    @Test func rootIsDirectSiblingAndEveryScratchUsesItsActualLogicalParent() async throws {
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory),
            .init(path: "Nested", kind: .directory), importFile("Nested/cafe\u{301}.txt"), importFile("plain")])
        let frozen = try await trial.freeze()
        #expect(frozen.layoutVersion == 2 && frozen.payloadPath == frozen.arenaPath)
        var mutations = 0
        for _ in 0..<30 {
            let work = try await trial.catalog.nextTreeImportWork(key: frozen.key, limit: 4)
            for item in work {
                if case .mutation(let step, let intent, let parent, let destinationParent) = item {
                    mutations += 1
                    if step == .arena {
                        #expect(intent.itemID == frozen.rootID && parent == frozen.scope.parentIdentity)
                        #expect(intent.destinationPath == frozen.arenaPath)
                    } else if step == .publish {
                        #expect(intent.sourcePath == frozen.arenaPath && parent == frozen.scope.parentIdentity)
                        #expect(destinationParent == frozen.scope.parentIdentity)
                    } else {
                        #expect(intent.itemID != frozen.rootID)
                        let path = try #require(intent.destinationPath)
                        let logicalParent = path.contains("/Nested/") ? frozen.arenaPath + "/Nested" : frozen.arenaPath
                        if step == .create {
                            #expect(Catalog.treeParent(path) == logicalParent)
                        } else {
                            #expect(Catalog.treeParent(try #require(intent.sourcePath)) == Catalog.treeParent(path))
                            #expect(parent == destinationParent)
                        }
                    }
                }
                _ = try await trial.apply(item)
            }
            if try await trial.catalog.treeImportStatus(rootID: frozen.rootID)?.phase == .published { break }
        }
        #expect(mutations == 8) // Root arena+publish, three non-root create/place pairs.
        let published = try #require(try await trial.catalog.treeImportStatus(rootID: frozen.rootID))
        #expect(published.result?.items.count == 1)
        #expect(try await trial.catalog.relativePath(id: published.rootID) == "Document.rtfd")
    }

    @Test func lineagePagesAndIndexedLookupPreserveCanonicalKeysAfterBindingChanges() async throws {
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("body")])
        let status = try await trial.freeze()
        _ = try await trial.readyToPublish()
        let history = try await trial.catalog.treeImportOperations(key: status.key, limit: 2)
        #expect(history.count == 2 && history[0].step == .arena && history[1].step == .create)
        let old = history[1], replacement = mutationUUID()
        let db = try SQLiteConnection(url: trial.fixture.url, cacheKiB: 2_048)
        try db.execute("UPDATE tree_import_nodes SET create_operation_key = ? WHERE operation_key = ? AND item_id = ?",
                       [.text(replacement.uuidString), .text(status.key.uuidString), .text(old.operation.intent.itemID)])
        let reopened = try Catalog(databaseURL: trial.fixture.url)
        #expect(try await reopened.treeImportOwner(operationKey: old.operation.intent.idempotencyKey)?.key == status.key)
        let exact = try #require(try await reopened.treeImportOperation(operationKey: old.operation.intent.idempotencyKey))
        #expect(exact.sequence == old.sequence && exact.parentIdentity == old.parentIdentity && exact.step == .create)
        let tail = try await reopened.treeImportOperations(key: status.key, afterSequence: old.sequence, limit: 1)
        #expect(tail.count == 1 && tail[0].step == .place)
        #expect(try await reopened.treeImportOperations(key: status.key, afterSequence: tail[0].sequence).isEmpty)
        #expect(try await reopened.treeImportOperation(operationKey: status.key) == nil)
        await #expect(throws: CatalogError.invalidPageSize) { try await reopened.treeImportOperations(key: status.key, limit: 0) }
        await #expect(throws: CatalogError.invalidEntry) { try await reopened.treeImportOperations(key: status.key, afterSequence: -1) }
        // Simulate an older unresolved attempt after a later binding replaced
        // it. Its durable journal truth blocks publication even with a verified
        // namespace and no currently visible unknown allocation pathname.
        try db.execute("UPDATE operations SET state = 'uncertain' WHERE idempotency_key = ?",
                       [.text(old.operation.intent.idempotencyKey.uuidString)])
        await #expect(throws: CatalogError.invalidTransition) { try await reopened.nextTreeImportWork(key: status.key) }
        #expect(try await reopened.knownItems().isEmpty)
        #expect(try await reopened.mutationResult(key: status.key) == nil)
    }

    @Test func schemaSevenPendingAndCompletedLayoutsRemainReadableButCannotResumeOrCleanup() async throws {
        for completed in [false, true] {
            let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("body")])
            let initial = try await trial.freeze()
            let before = completed ? try await trial.finish() : initial
            let db = try SQLiteConnection(url: trial.fixture.url, cacheKiB: 2_048)
            let retiredKey = mutationUUID()
            if !completed {
                let itemID = try db.scalarText("SELECT item_id FROM tree_import_nodes WHERE operation_key = ? AND path = 'body'",
                                              [.text(initial.key.uuidString)])
                let scratch = try db.scalarText("SELECT scratch_path FROM tree_import_nodes WHERE operation_key = ? AND path = 'body'",
                                               [.text(initial.key.uuidString)])
                let historical = JournalIntent(idempotencyKey: retiredKey, itemID: itemID, expectedVersion: nil,
                    action: .create(parentID: initial.rootID, name: Catalog.treeName(scratch), kind: .file),
                    payload: trial.entries[1].payload, destinationPath: scratch)
                try insertTreeTestOperation(historical, in: db, state: .uncertain, fingerprint: false)
            }
            let originalIntent = try db.scalarText("SELECT intent FROM operations WHERE idempotency_key = ?", [.text(initial.key.uuidString)])
            try db.script("ALTER TABLE observed_directories DROP COLUMN is_complete; DROP TABLE tree_import_operations; ALTER TABLE tree_imports DROP COLUMN layout_version; PRAGMA user_version=7;")
            let migrated = try Catalog(databaseURL: trial.fixture.url)
            let legacy = try #require(try await migrated.treeImportStatus(rootID: initial.rootID))
            #expect(legacy.layoutVersion == 1 && legacy.phase == before.phase && legacy.tree == before.tree)
            #expect(legacy.payloadPath == legacy.arenaPath + "/payload")
            #expect(legacy.result == before.result)
            #expect(try db.scalarText("SELECT intent FROM operations WHERE idempotency_key = ?", [.text(initial.key.uuidString)]) == originalIntent)
            #expect(try db.scalarInt("PRAGMA user_version") == 9)
            if !completed {
                #expect(try await migrated.treeImportOwner(operationKey: retiredKey)?.key == initial.key)
                #expect(try await migrated.operation(key: retiredKey)?.state == .uncertain)
            }
            await #expect(throws: CatalogError.invalidTransition) { try await migrated.nextTreeImportWork(key: legacy.key) }
            await #expect(throws: CatalogError.invalidTransition) { try await migrated.stageTreeImport(key: legacy.key, entries: []) }
            await #expect(throws: CatalogError.invalidTransition) {
                try await migrated.recordTreeImportProgress(key: legacy.key, update: .blocked(code: "must-not-clean-published-root"))
            }
            await #expect(throws: CatalogError.invalidTransition) { try await migrated.prepareTreeImport(intent: trial.intent, scope: trial.scope) }
        }
    }
}
