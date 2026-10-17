import Testing
@testable import MyDriveCore

@Suite struct TreeImportTests {
    @Test func frozenTreeIntakeRestartsWithoutPublishingOrChangingLegacyFingerprints() async throws {
        let entries: [TreeImportEntry] = [.init(path: "", kind: .directory), .init(path: "Nested", kind: .directory),
            importFile("Nested/body"), importFile("plain")]
        let trial = try await ImportTrial(entries: entries)
        let prepared = try await trial.prepare()
        let generation = try await trial.catalog.generation(), anchor = try await trial.catalog.currentChangeAnchor()
        #expect(prepared.phase == .building && prepared.tree.nodeCount == 4)
        _ = try await trial.catalog.stageTreeImport(key: prepared.key, entries: Array(entries.prefix(2)))
        let reopened = try Catalog(databaseURL: trial.fixture.url)
        #expect(try await reopened.treeImportStatus(rootID: prepared.rootID)?.tree == prepared.tree)
        #expect(try await reopened.treeImportStatus(rootID: "unrelated") == nil)
        await #expect(throws: CatalogError.invalidTransition) { try await reopened.nextTreeImportWork(key: prepared.key) }
        await #expect(throws: CatalogError.invalidEntry) {
            try await reopened.stageTreeImport(key: prepared.key, entries: [], sealedDirectories: [""], isComplete: true)
        }
        // Failed complete is atomic: it did not seal the root and prevent the
        // immutable local snapshot's remaining children from being staged.
        _ = try await reopened.stageTreeImport(key: prepared.key, entries: Array(entries.suffix(2)))
        let frozen = try await reopened.stageTreeImport(key: prepared.key, entries: [],
            sealedDirectories: ["Nested", ""], isComplete: true)
        #expect(frozen.phase == .frozen)
        #expect(try await reopened.knownItems().isEmpty)
        #expect(try await reopened.generation() == generation)
        #expect(try await reopened.currentChangeAnchor() == anchor)
        #expect(try await reopened.operation(key: prepared.key)?.state == .queued)
        let finished = try await trial.finish(in: reopened)
        #expect(finished.phase == .published && finished.result?.items.count == 1)
        #expect(try await reopened.relativePath(id: finished.rootID) == "Document.rtfd")
        let nested = try #require(try await reopened.child(named: "Nested", in: finished.rootID))
        #expect(try await reopened.child(named: "body", in: nested.id)?.entry.size == 42)
    }

    @Test func semanticRetryReturnsOriginalSourceButChangedTreeOrWireNameCannotReuseKey() async throws {
        let entries: [TreeImportEntry] = [.init(path: "", kind: .directory), importFile("cafe\u{301}")]
        let trial = try await ImportTrial(entries: entries)
        let original = try await trial.prepare()
        let equivalentTree = try importTreeReference([.init(path: "", kind: .directory), importFile("cafe\u{301}")])
        let retry = JournalIntent(itemID: trial.intent.itemID, expectedVersion: nil, action: trial.intent.action,
            createTemplateID: trial.intent.createTemplateID, destinationPath: trial.intent.destinationPath, tree: equivalentTree)
        #expect(retry.requestFingerprint == trial.intent.requestFingerprint)
        let canonical = try await trial.catalog.prepareTreeImport(intent: retry, scope: trial.scope)
        #expect(canonical.key == original.key && canonical.tree.id == original.tree.id)
        let changedTree = try importTreeReference([.init(path: "", kind: .directory), importFile("caf\u{e9}")])
        let changed = JournalIntent(idempotencyKey: trial.intent.idempotencyKey, itemID: trial.intent.itemID,
            expectedVersion: nil, action: trial.intent.action, createTemplateID: trial.intent.createTemplateID,
            destinationPath: trial.intent.destinationPath, tree: changedTree)
        #expect(changed.requestFingerprint != retry.requestFingerprint)
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await trial.catalog.prepareTreeImport(intent: changed, scope: trial.scope)
        }
        // Every private operation must stay behind the import boundary even
        // when an ordinary commit could otherwise manufacture the same ID.
        await #expect(throws: CatalogError.invalidTransition) {
            try await trial.catalog.commitMutation(key: original.key, upserts: [.init(id: original.rootID,
                parentID: Catalog.rootID, entry: .init(name: original.filename, kind: .directory,
                    contentVersion: "unverified", metadataVersion: "unverified"))], tombstones: [])
        }
    }

    @Test func privateReceiptsAreDurableAndCannotUseOrdinaryCatalogPublication() async throws {
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("file")])
        let frozen = try await trial.freeze()
        let work = try #require(try await trial.catalog.nextTreeImportWork(key: frozen.key).first)
        guard case .mutation(let step, let intent, _, _) = work else { throw CatalogError.invalidEntry }
        let operation = try await trial.catalog.enqueueTreeImportChild(key: frozen.key, step: step, intent: intent)
        try await trial.catalog.transitionOperation(key: operation.intent.idempotencyKey, from: .queued, to: .executing)
        let entry = try trial.outcome(step: step, intent: intent)
        await #expect(throws: CatalogError.invalidTransition) {
            try await trial.catalog.commitMutation(key: operation.intent.idempotencyKey,
                upserts: [.init(id: intent.itemID, parentID: Catalog.rootID, entry: entry)], tombstones: [])
        }
        let status = try await trial.catalog.recordTreeImportProgress(key: frozen.key,
            update: .committed(step: step, key: operation.intent.idempotencyKey, entry: entry, sha256: nil))
        trial.observeArena(entry)
        #expect(status.arena?.objectIdentity == entry.objectIdentity)
        #expect(try await trial.catalog.knownItems().isEmpty)
        let reopened = try Catalog(databaseURL: trial.fixture.url)
        #expect(try await reopened.mutationResult(key: operation.intent.idempotencyKey)?.items.first?.entry == entry)
        #expect(try await reopened.operation(key: operation.intent.idempotencyKey)?.state == .completed)
        _ = try await reopened.recordTreeImportProgress(key: frozen.key,
            update: .committed(step: step, key: operation.intent.idempotencyKey, entry: entry, sha256: nil))
        let changed = RemoteEntry(name: entry.name, kind: entry.kind, contentVersion: "other", metadataVersion: "other",
                                  objectIdentity: entry.objectIdentity)
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await reopened.recordTreeImportProgress(key: frozen.key,
                update: .committed(step: step, key: operation.intent.idempotencyKey, entry: changed, sha256: nil))
        }
        let finished = try await trial.finish(in: reopened)
        #expect(finished.result?.items.count == 1)
        #expect(try await reopened.replayableOperations().isEmpty)
    }

    @Test func finalPublicationExceedsLegacyBatchBoundButReceiptAndPagesStayBounded() async throws {
        let entries: [TreeImportEntry] = [.init(path: "", kind: .directory)]
            + (0..<1_025).map { importFile("file-" + String(10_000 + $0)) }
        let trial = try await ImportTrial(entries: entries)
        let frozen = try await trial.freeze()
        let before = try await trial.catalog.generation(), anchor = try await trial.catalog.currentChangeAnchor()
        _ = try await trial.placeAll()
        #expect(try await trial.catalog.knownItems().isEmpty)
        #expect(try await trial.catalog.currentChangeAnchor() == anchor)
        let finished = try await trial.finish()
        #expect(finished.verifiedNodes == 1_026)
        #expect(finished.result?.items.count == 1 && finished.result?.items.first?.id == frozen.rootID)
        #expect(try await trial.catalog.generation() == before + 1)
        var cursor: ListingCursor?, count = 0
        repeat {
            let page = try await trial.catalog.children(of: frozen.rootID, after: cursor, limit: 37)
            #expect(page.items.count <= 37)
            count += page.items.count; cursor = page.nextCursor
        } while cursor != nil
        #expect(count == 1_025)
        #expect(try await trial.catalog.hasCompletedScan(of: frozen.rootID))
        let reopened = try Catalog(databaseURL: trial.fixture.url)
        #expect(try await reopened.mutationResult(key: frozen.key) == finished.result)
        #expect(try await reopened.nextTreeImportWork(key: frozen.key).isEmpty)
        #expect(try await reopened.treeImportStatus(rootID: frozen.rootID)?.phase == .published)
        var sequence: Int64?, historyCount = 0
        while true {
            let page = try await reopened.treeImportOperations(key: frozen.key, afterSequence: sequence, limit: 37)
            #expect(page.count <= 37)
            guard let last = page.last else { break }
            #expect(page.allSatisfy { $0.operation.state == .completed })
            historyCount += page.count; sequence = last.sequence
        }
        #expect(historyCount == 2_052) // Arena+publish and two operations for each non-root.
        let db = try SQLiteConnection(url: trial.fixture.url, cacheKiB: 2_048)
        #expect(try db.scalarInt("SELECT count(*) FROM items WHERE is_deleted = 0 AND id != 'root'") == 1_026)
        #expect(try db.scalarInt("SELECT length(result) FROM operations WHERE idempotency_key = ?", [.text(frozen.key.uuidString)]) < 4_096)
    }
}
