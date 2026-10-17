import Testing
@testable import MyDriveCore

@Suite struct MutationTests {
    @Test func createTemplateAndPayloadSurviveRestartAndDeduplicateRetries() async throws {
        let fixture = try Fixture()
        let id = try await fixture.catalog.providerID(forCreateTemplate: "os-template-1")
        let first = intent(id: id, template: "os-template-1")
        let queued = try await fixture.catalog.enqueue(first)
        let reopened = try Catalog(databaseURL: fixture.url)
        #expect(try await reopened.providerID(forCreateTemplate: "os-template-1") == id)
        let retry = intent(id: id, template: "os-template-1")
        #expect(retry.idempotencyKey != first.idempotencyKey)
        #expect(retry.payload?.id != first.payload?.id)
        #expect(retry.requestFingerprint == first.requestFingerprint)
        #expect(try await reopened.enqueue(retry) == queued)
        #expect(try await reopened.operation(requestFingerprint: retry.requestFingerprint) == queued)
        #expect(try await reopened.replayableOperations().count == 1)
        #expect(try await reopened.item(id: id) == nil) // Preparing is never publication.
    }

    @Test func committedReceiptIsAtomicDurableAndIndependentOfLaterScans() async throws {
        let fixture = try Fixture()
        let id = try await fixture.catalog.providerID(forCreateTemplate: "create")
        let request = intent(id: id, template: "create")
        try await start(request, in: fixture.catalog)
        let before = try await fixture.catalog.generation()
        let observed = CatalogMutationItem(id: id, parentID: Catalog.rootID, entry: file("new.txt"))
        let result = try await fixture.catalog.commitMutation(key: request.idempotencyKey, upserts: [observed], tombstones: [])
        #expect(result.generation == before + 1)
        #expect(result.items.first?.id == id)
        #expect(try await fixture.catalog.operation(key: request.idempotencyKey)?.state == .completed)
        let reopened = try Catalog(databaseURL: fixture.url)
        #expect(try await reopened.mutationResult(key: request.idempotencyKey) == result)
        #expect(try await reopened.replayableOperations().isEmpty)
        #expect(try await reopened.commitMutation(key: request.idempotencyKey, upserts: [observed], tombstones: []) == result)
        try await publish([], to: reopened)
        #expect(try await reopened.item(id: id)?.isDeleted == true)
        #expect(try await reopened.mutationResult(key: request.idempotencyKey)?.items.first?.isDeleted == false)
        let changed = CatalogMutationItem(id: id, parentID: Catalog.rootID, entry: file("different.txt"))
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await reopened.commitMutation(key: request.idempotencyKey, upserts: [changed], tombstones: [])
        }
    }

    @Test func invalidCollisionRollsBackItemJournalGenerationAndChangeFeed() async throws {
        let fixture = try Fixture()
        try await publish([file("taken")], to: fixture.catalog)
        let id = try await fixture.catalog.providerID(forCreateTemplate: "collision")
        let request = intent(id: id, name: "taken", template: "collision")
        try await start(request, in: fixture.catalog)
        let generation = try await fixture.catalog.generation()
        let anchor = try await fixture.catalog.currentChangeAnchor()
        await #expect(throws: CatalogError.invalidEntry) {
            try await fixture.catalog.commitMutation(key: request.idempotencyKey,
                upserts: [CatalogMutationItem(id: id, parentID: Catalog.rootID, entry: file("taken"))], tombstones: [])
        }
        #expect(try await fixture.catalog.item(id: id) == nil)
        #expect(try await fixture.catalog.children().items.count == 1)
        #expect(try await fixture.catalog.generation() == generation)
        #expect(try await fixture.catalog.currentChangeAnchor() == anchor)
        #expect(try await fixture.catalog.mutationResult(key: request.idempotencyKey) == nil)
        #expect(try await fixture.catalog.operation(key: request.idempotencyKey)?.state == .executing)
    }

    @Test func olderDirectoryScanCannotUndoNewlyCommittedCreate() async throws {
        let fixture = try Fixture()
        let stale = try await fixture.catalog.beginScan()
        let id = try await fixture.catalog.providerID(forCreateTemplate: "new-after-scan")
        let request = intent(id: id, template: "new-after-scan")
        try await start(request, in: fixture.catalog)
        try await fixture.catalog.commitMutation(key: request.idempotencyKey,
            upserts: [CatalogMutationItem(id: id, parentID: Catalog.rootID, entry: file("new.txt"))], tombstones: [])
        await #expect(throws: CatalogError.invalidScan) { try await fixture.catalog.completeScan(stale) }
        #expect(try await fixture.catalog.item(id: id)?.isDeleted == false)
    }

    @Test func conflictPublishesBothCopiesWithStableLocalIDAndPolicy() async throws {
        let fixture = try Fixture()
        let original = RemoteEntry(name: "document", kind: .file, remoteKey: "original-key",
            contentVersion: "old", metadataVersion: "old", size: 42)
        try await publish([original], to: fixture.catalog)
        let localID = try #require(try await fixture.catalog.children().items.first?.id)
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: localID)
        let request = JournalIntent(itemID: localID, expectedVersion: "old",
            action: .update(parentID: Catalog.rootID, name: "conflict"),
            expectedMetadataVersion: "old", payload: payload(), baseEntry: original)
        try await start(request, in: fixture.catalog)
        let local = RemoteEntry(name: "conflict", kind: .file, remoteKey: "new-key",
            contentVersion: "local", metadataVersion: "local", size: 42)
        try await fixture.catalog.commitMutation(key: request.idempotencyKey, upserts: [
            CatalogMutationItem(id: "a-remote-copy", parentID: Catalog.rootID, entry: original),
            CatalogMutationItem(id: localID, parentID: Catalog.rootID, entry: local)
        ], tombstones: [])
        #expect(try await fixture.catalog.item(id: localID)?.entry.contentVersion == "local")
        #expect(try await fixture.catalog.offlinePolicy(for: localID) == .keepAvailable)
        #expect(try await fixture.catalog.offlinePolicy(for: "a-remote-copy") == .onDemand)
        #expect(try await fixture.catalog.children().items.count == 2)
    }

    @Test func mismatchedPayloadSizeCannotPublishSuccessfulWrite() async throws {
        let fixture = try Fixture()
        let id = try await fixture.catalog.providerID(forCreateTemplate: "size-check")
        let request = intent(id: id, template: "size-check")
        try await start(request, in: fixture.catalog)
        await #expect(throws: CatalogError.invalidEntry) {
            try await fixture.catalog.commitMutation(key: request.idempotencyKey, upserts: [
                CatalogMutationItem(id: id, parentID: Catalog.rootID,
                    entry: RemoteEntry(name: "new.txt", kind: .file, contentVersion: "v", metadataVersion: "m", size: 41))
            ], tombstones: [])
        }
        #expect(try await fixture.catalog.item(id: id) == nil)
        #expect(try await fixture.catalog.operation(key: request.idempotencyKey)?.state == .executing)
    }

    @Test func cyclesAndFileParentsCannotPublish() async throws {
        let fixture = try Fixture()
        let id = try await fixture.catalog.providerID(forCreateTemplate: "folder")
        let request = JournalIntent(itemID: id, expectedVersion: nil,
            action: .create(parentID: Catalog.rootID, name: "folder", kind: .directory), createTemplateID: "folder")
        try await start(request, in: fixture.catalog)
        await #expect(throws: CatalogError.invalidParent) {
            try await fixture.catalog.commitMutation(key: request.idempotencyKey, upserts: [
                CatalogMutationItem(id: id, parentID: "second", entry: directory("folder")),
                CatalogMutationItem(id: "second", parentID: id, entry: directory("second"))
            ], tombstones: [])
        }
        await #expect(throws: CatalogError.invalidParent) {
            try await fixture.catalog.commitMutation(key: request.idempotencyKey, upserts: [
                CatalogMutationItem(id: id, parentID: "parent-file", entry: directory("folder")),
                CatalogMutationItem(id: "parent-file", parentID: Catalog.rootID, entry: file("parent-file"))
            ], tombstones: [])
        }
        #expect(try await fixture.catalog.knownItems().isEmpty)
    }

    @Test func unsortedNewParentsCommitTogether() async throws {
        let fixture = try Fixture()
        let id = try await fixture.catalog.providerID(forCreateTemplate: "nested-file")
        // Parent must exist at prepare time; a verified remote conflict result
        // may additionally publish a new nested directory and move this ID there.
        let request = intent(id: id, template: "nested-file")
        try await start(request, in: fixture.catalog)
        let result = try await fixture.catalog.commitMutation(key: request.idempotencyKey, upserts: [
            CatalogMutationItem(id: id, parentID: "z-parent", entry: file("new.txt")),
            CatalogMutationItem(id: "z-parent", parentID: Catalog.rootID, entry: directory("folder"))
        ], tombstones: [])
        #expect(result.items.count == 2)
        #expect(try await fixture.catalog.relativePath(id: id) == "folder/new.txt")
    }

    @Test func deleteRetiresDescendantsButKeepsChildMovedOutInSameCommit() async throws {
        let fixture = try Fixture()
        try await publish([directory("old")], to: fixture.catalog)
        let old = try #require(try await fixture.catalog.children().items.first)
        let nested = try await fixture.catalog.beginScan(of: old.id)
        try await fixture.catalog.stage([directory("saved"), file("retired")], in: nested)
        try await fixture.catalog.completeScan(nested)
        let children = try await fixture.catalog.children(of: old.id).items
        let saved = try #require(children.first { $0.entry.name == "saved" })
        let retired = try #require(children.first { $0.entry.name == "retired" })
        let scan = try await fixture.catalog.beginScan(of: saved.id)
        try await fixture.catalog.stage([file("inside")], in: scan)
        try await fixture.catalog.completeScan(scan)
        let inside = try #require(try await fixture.catalog.children(of: saved.id).items.first)
        let interrupted = try await fixture.catalog.beginScan(of: old.id)
        try await fixture.catalog.stage([file("stale")], in: interrupted)
        let request = JournalIntent(itemID: old.id, expectedVersion: "v1", action: .delete)
        try await start(request, in: fixture.catalog)
        let anchor = try await fixture.catalog.currentChangeAnchor()
        let result = try await fixture.catalog.commitMutation(key: request.idempotencyKey,
            upserts: [CatalogMutationItem(id: saved.id, parentID: Catalog.rootID, entry: directory("saved"))],
            tombstones: [old.id])
        #expect(result.tombstones == [old.id])
        #expect(try await fixture.catalog.item(id: retired.id)?.isDeleted == true)
        #expect(try await fixture.catalog.relativePath(id: inside.id) == "saved/inside")
        let changes = try await fixture.catalog.changes(since: anchor)
        #expect(Set(changes.deletedIDs) == [old.id, retired.id])
        #expect(changes.updated.map(\.id) == [saved.id])
        await #expect(throws: CatalogError.invalidScan) { try await fixture.catalog.completeScan(interrupted) }
    }

    @Test func replacementUsesFreshIdentityAndTombstonesOldDirectoryTree() async throws {
        let fixture = try Fixture()
        try await publish([directory("document")], to: fixture.catalog)
        let old = try #require(try await fixture.catalog.children().items.first)
        let scan = try await fixture.catalog.beginScan(of: old.id)
        try await fixture.catalog.stage([file("inside")], in: scan)
        try await fixture.catalog.completeScan(scan)
        let child = try #require(try await fixture.catalog.children(of: old.id).items.first)
        let newID = try await fixture.catalog.providerID(forCreateTemplate: "replacement")
        let request = intent(id: newID, name: "document", template: "replacement")
        try await start(request, in: fixture.catalog)
        try await fixture.catalog.commitMutation(key: request.idempotencyKey,
            upserts: [CatalogMutationItem(id: newID, parentID: Catalog.rootID, entry: file("document"))], tombstones: [old.id])
        #expect(try await fixture.catalog.item(id: old.id)?.isDeleted == true)
        #expect(try await fixture.catalog.item(id: child.id)?.isDeleted == true)
        #expect(try await fixture.catalog.children().items.map(\.id) == [newID])
    }

    @Test func interruptedWritePreservesOpaqueBaseAndStagingForReconciliation() async throws {
        let fixture = try Fixture()
        try await publish([file("old")], to: fixture.catalog)
        let item = try #require(try await fixture.catalog.children().items.first)
        let request = JournalIntent(itemID: item.id, expectedVersion: item.entry.contentVersion,
            action: .update(parentID: Catalog.rootID, name: "changed"),
            expectedMetadataVersion: item.entry.metadataVersion, payload: payload(),
            sourcePath: "old", destinationPath: "changed", baseEntry: item.entry)
        try await start(request, in: fixture.catalog)
        let reopened = try Catalog(databaseURL: fixture.url)
        try await reopened.recoverInterruptedOperations()
        let recovered = try #require(try await reopened.replayableOperations().first)
        #expect(recovered.intent == request)
        #expect(recovered.state == .uncertain)
        #expect(recovered.intent.sourcePath == "old")
        #expect(recovered.intent.payload == request.payload)
        try await reopened.commitMutation(key: recovered.intent.idempotencyKey,
            upserts: [CatalogMutationItem(id: item.id, parentID: Catalog.rootID, entry: file("changed"))], tombstones: [])
        #expect(try await reopened.relativePath(id: item.id) == "changed")
    }

    @Test func fingerprintPreservesExactUnicodeAndOpaqueVersions() throws {
        let a = intent(id: "id", name: "caf\u{e9}")
        let b = intent(id: "id", name: "cafe\u{301}")
        #expect(a.requestFingerprint != b.requestFingerprint)
        #expect(a.requestFingerprint == intent(id: "id", name: "caf\u{e9}").requestFingerprint)
        let changedPayload = JournalIntent(itemID: "id", expectedVersion: nil,
            action: a.action, payload: StagedPayload(id: mutationUUID(), size: 42, sha256: String(repeating: "b", count: 64)))
        #expect(a.requestFingerprint != changedPayload.requestFingerprint)
    }

    @Test func explicitKeyRejectsByteDistinctEquivalentUnicodeInEverySnapshotField() async throws {
        let fixture = try Fixture()
        try await publish([file("caf\u{e9}")], to: fixture.catalog)
        let id = try #require(try await fixture.catalog.children().items.first?.id)
        let nfc = "caf\u{e9}"
        let nfd = "cafe\u{301}"
        let key = mutationUUID()
        func request(name: String = "caf\u{e9}", source: String = "caf\u{e9}",
                     destination: String = "caf\u{e9}", baseName: String = "caf\u{e9}",
                     content: String = "caf\u{e9}", metadata: String = "caf\u{e9}") -> JournalIntent {
            JournalIntent(idempotencyKey: key, itemID: id, expectedVersion: content,
                action: .update(parentID: Catalog.rootID, name: name), expectedMetadataVersion: metadata,
                sourcePath: source, destinationPath: destination,
                baseEntry: RemoteEntry(name: baseName, kind: .file, contentVersion: content, metadataVersion: metadata))
        }
        #expect(nfc == nfd) // Swift equality alone cannot protect the wire intent.
        let original = request()
        _ = try await fixture.catalog.enqueue(original)
        for changed in [request(name: nfd), request(source: nfd), request(destination: nfd),
                        request(baseName: nfd), request(content: nfd), request(metadata: nfd)] {
            #expect(changed.requestFingerprint != original.requestFingerprint)
            await #expect(throws: CatalogError.idempotencyConflict) { try await fixture.catalog.enqueue(changed) }
        }
    }

    @Test func createTemplateBindingUsesExactUTF8AndSurvivesRestart() async throws {
        let fixture = try Fixture()
        let first = try await fixture.catalog.providerID(forCreateTemplate: "caf\u{e9}")
        let second = try await fixture.catalog.providerID(forCreateTemplate: "cafe\u{301}")
        #expect(first != second)
        let reopened = try Catalog(databaseURL: fixture.url)
        #expect(try await reopened.providerID(forCreateTemplate: "caf\u{e9}") == first)
        #expect(try await reopened.providerID(forCreateTemplate: "cafe\u{301}") == second)
    }

    @Test func malformedPayloadAndUnboundCreateFailBeforeEnqueue() async throws {
        let fixture = try Fixture()
        let malformed = JournalIntent(itemID: "new", expectedVersion: nil,
            action: .create(parentID: Catalog.rootID, name: "new", kind: .file),
            payload: StagedPayload(id: mutationUUID(), size: 0, sha256: "bad"))
        await #expect(throws: CatalogError.invalidEntry) { try await fixture.catalog.enqueue(malformed) }
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await fixture.catalog.enqueue(intent(id: "not-bound", template: "unallocated"))
        }
        #expect(try await fixture.catalog.replayableOperations().isEmpty)
    }

    @Test func legacyMigrationPreservesHistoryAndAllowsUnpublishedCreateID() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("legacy.sqlite")
        let db = try SQLiteConnection(url: path, cacheKiB: 2_048)
        try db.script("""
            CREATE TABLE items(id TEXT PRIMARY KEY);
            INSERT INTO items VALUES ('old');
            CREATE TABLE operations(sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                idempotency_key TEXT NOT NULL UNIQUE, item_id TEXT NOT NULL REFERENCES items(id),
                intent TEXT NOT NULL, state TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX replay ON operations(state, sequence);
            INSERT INTO operations VALUES (7, 'legacy', 'old', '{}', 'uncertain', 3);
            """)
        try db.transaction { try db.migrateWritableJournal() }
        #expect(try db.scalarInt("SELECT sequence FROM operations") == 7)
        #expect(try db.scalarInt("SELECT attempt_count FROM operations") == 3)
        #expect(try db.scalarText("SELECT state FROM operations") == "uncertain")
        try db.execute("INSERT INTO operations(idempotency_key,item_id,intent,state) VALUES ('new','unpublished','{}','queued')")
        #expect(try db.scalarInt("SELECT max(sequence) FROM operations") == 8)
        #expect(try db.scalarInt("SELECT count(*) FROM pragma_foreign_key_check") == 0)
    }

    private func intent(id: String, name: String = "new.txt", template: String? = nil) -> JournalIntent {
        JournalIntent(itemID: id, expectedVersion: nil,
            action: .create(parentID: Catalog.rootID, name: name, kind: .file),
            payload: payload(), createTemplateID: template)
    }

    private func payload() -> StagedPayload {
        StagedPayload(id: mutationUUID(), size: 42, sha256: String(repeating: "a", count: 64))
    }

    private func file(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, contentVersion: "opaque-v1", metadataVersion: "opaque-m1", size: 42)
    }

    private func directory(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, kind: .directory, contentVersion: "v1", metadataVersion: "m1")
    }

    private func publish(_ values: [RemoteEntry], to catalog: Catalog) async throws {
        let scan = try await catalog.beginScan()
        try await catalog.stage(values, in: scan)
        try await catalog.completeScan(scan)
    }

    private func start(_ intent: JournalIntent, in catalog: Catalog) async throws {
        _ = try await catalog.enqueue(intent)
        try await catalog.transitionOperation(key: intent.idempotencyKey, from: .queued, to: .executing)
    }
}
