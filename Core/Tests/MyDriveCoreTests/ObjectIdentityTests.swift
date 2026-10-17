import Testing
@testable import MyDriveCore

@Suite struct ObjectIdentityTests {
    @Test func remoteAtomicFileSavePreservesLogicalIDPendingLocalBaseAndOfflineSelection() async throws {
        let fixture = try Fixture()
        let old = RemoteEntry(name: "document", kind: .file, contentVersion: "old-version", metadataVersion: "old-metadata",
                              size: 42, objectIdentity: .init(indexNumber: 10, createdFiletime: 11))
        try await publish([old], to: fixture.catalog)
        let original = try #require(try await fixture.catalog.child(named: "document", in: Catalog.rootID))
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: original.id)
        let local = JournalIntent(itemID: original.id, expectedVersion: old.contentVersion,
            action: .update(parentID: Catalog.rootID, name: "document"), expectedMetadataVersion: old.metadataVersion,
            payload: .init(id: mutationUUID(), size: 42, sha256: String(repeating: "a", count: 64)), baseEntry: old)
        _ = try await fixture.catalog.enqueue(local)
        let remoteSave = RemoteEntry(name: "document", kind: .file, contentVersion: "external-save", metadataVersion: "external-metadata",
                                    size: 99, objectIdentity: .init(indexNumber: 20, createdFiletime: 21))
        let anchor = try await fixture.catalog.currentChangeAnchor()
        try await publish([remoteSave], to: fixture.catalog)
        let current = try #require(try await fixture.catalog.child(named: "document", in: Catalog.rootID))
        #expect(current.id == original.id)
        #expect(current.entry.objectIdentity == remoteSave.objectIdentity)
        #expect(current.entry.contentVersion == "external-save")
        #expect(try await fixture.catalog.offlinePolicy(for: original.id) == .keepAvailable)
        #expect(try await fixture.catalog.operation(key: local.idempotencyKey)?.intent.baseEntry == old)
        #expect(try await fixture.catalog.changes(since: anchor).deletedIDs.isEmpty)
        // The old ID remains publishable for a preserved local conflict copy.
        try await fixture.catalog.transitionOperation(key: local.idempotencyKey, from: .queued, to: .executing)
        let preservedLocal = RemoteEntry(name: "document conflict", kind: .file, contentVersion: "local", metadataVersion: "local",
                                        size: 42, objectIdentity: .init(indexNumber: 30, createdFiletime: 31))
        try await fixture.catalog.commitMutation(key: local.idempotencyKey, upserts: [
            .init(id: original.id, parentID: Catalog.rootID, entry: preservedLocal),
            .init(id: "preserved-external", parentID: Catalog.rootID, entry: remoteSave)
        ], tombstones: [])
        #expect(try await fixture.catalog.child(named: "document conflict", in: Catalog.rootID)?.id == original.id)
        #expect(try await fixture.catalog.child(named: "document", in: Catalog.rootID)?.entry == remoteSave)
    }

    @Test func unsignedIdentityPersistsThroughStagingRestartAndPublication() async throws {
        let fixture = try Fixture()
        let identity = RemoteObjectIdentity(indexNumber: .max, createdFiletime: .max)
        let scan = try await fixture.catalog.beginScan()
        try await fixture.catalog.stage([entry("file", identity: identity)], in: scan)
        let reopened = try Catalog(databaseURL: fixture.url)
        try await reopened.completeScan(scan)
        let item = try #require(try await reopened.child(named: "file", in: Catalog.rootID))
        #expect(item.entry.objectIdentity == identity)
        let db = try SQLiteConnection(url: fixture.url, cacheKiB: 2_048)
        #expect(try db.scalarText("SELECT object_index_number FROM items WHERE id = ?", [.text(item.id)]) == "18446744073709551615")
        #expect(try db.scalarText("SELECT typeof(object_created_filetime) FROM items WHERE id = ?", [.text(item.id)]) == "text")
        #expect(try db.scalarInt("PRAGMA user_version") == 7)
    }

    @Test func identityAdoptionPublishesOnceAndMissingLegacyMetadataCannotEraseIt() async throws {
        let fixture = try Fixture()
        try await publish([entry("file")], to: fixture.catalog)
        let original = try #require(try await fixture.catalog.child(named: "file", in: Catalog.rootID))
        let anchor = try await fixture.catalog.currentChangeAnchor()
        let generation = try await fixture.catalog.generation()
        let identity = RemoteObjectIdentity(indexNumber: 7, createdFiletime: 11)
        try await publish([entry("file", identity: identity)], to: fixture.catalog)
        let adopted = try #require(try await fixture.catalog.child(named: "file", in: Catalog.rootID))
        #expect(adopted.id == original.id)
        #expect(adopted.entry.objectIdentity == identity)
        #expect(try await fixture.catalog.generation() == generation + 1)
        #expect(try await fixture.catalog.changes(since: anchor).updated.map(\.id) == [original.id])
        let adoptedGeneration = try await fixture.catalog.generation()
        try await publish([entry("file")], to: fixture.catalog)
        #expect(try await fixture.catalog.item(id: original.id)?.entry.objectIdentity == identity)
        #expect(try await fixture.catalog.generation() == adoptedGeneration)
    }

    @Test func replacementDirectoryRetiresDescendantsAndDoesNotInheritOldSelection() async throws {
        let fixture = try Fixture()
        let originalIdentity = RemoteObjectIdentity(indexNumber: 20, createdFiletime: 30)
        try await publish([entry("folder", kind: .directory, identity: originalIdentity)], to: fixture.catalog)
        let folder = try #require(try await fixture.catalog.child(named: "folder", in: Catalog.rootID))
        try await publish([entry("child", identity: .init(indexNumber: 21, createdFiletime: 31))], to: fixture.catalog, parent: folder.id)
        let child = try #require(try await fixture.catalog.child(named: "child", in: folder.id))
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: folder.id)
        let anchor = try await fixture.catalog.currentChangeAnchor()
        // Reuse the server number but change creation identity. Opaque versions
        // deliberately stay equal, so parsing or comparing them cannot help.
        try await publish([entry("folder", kind: .directory, identity: .init(indexNumber: 20, createdFiletime: 99))], to: fixture.catalog)
        let replacement = try #require(try await fixture.catalog.child(named: "folder", in: Catalog.rootID))
        #expect(replacement.id != folder.id)
        #expect(try await fixture.catalog.item(id: folder.id)?.isDeleted == true)
        #expect(try await fixture.catalog.item(id: child.id)?.isDeleted == true)
        #expect(try await fixture.catalog.offlinePolicy(for: replacement.id) == .onDemand)
        #expect(try await fixture.catalog.children(of: replacement.id).items.isEmpty)
        let changes = try await fixture.catalog.changes(since: anchor)
        #expect(Set(changes.deletedIDs) == [folder.id, child.id])
        #expect(changes.updated.map(\.id) == [replacement.id])
    }

    @Test func changedLegacyDirectoryVersionCannotAdoptAReplacementObject() async throws {
        let fixture = try Fixture()
        try await publish([entry("folder", kind: .directory)], to: fixture.catalog)
        let original = try #require(try await fixture.catalog.child(named: "folder", in: Catalog.rootID))
        try await publish([entry("pending-child")], to: fixture.catalog, parent: original.id)
        let child = try #require(try await fixture.catalog.child(named: "pending-child", in: original.id))
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: original.id)
        let replacement = RemoteEntry(name: "folder", kind: .directory,
            contentVersion: "different opaque token", metadataVersion: "different opaque metadata",
            objectIdentity: .init(indexNumber: 9, createdFiletime: 10))
        try await publish([replacement], to: fixture.catalog)
        let observed = try #require(try await fixture.catalog.child(named: "folder", in: Catalog.rootID))
        #expect(observed.id != original.id)
        #expect(observed.entry.objectIdentity == replacement.objectIdentity)
        #expect(try await fixture.catalog.item(id: original.id)?.isDeleted == true)
        #expect(try await fixture.catalog.item(id: child.id)?.isDeleted == true)
        #expect(try await fixture.catalog.offlinePolicy(for: observed.id) == .onDemand)
    }

    @Test func mutationReceiptAndFingerprintsIncludeTypedIdentity() async throws {
        let fixture = try Fixture()
        let id = try await fixture.catalog.providerID(forCreateTemplate: "new")
        let intent = JournalIntent(itemID: id, expectedVersion: nil,
            action: .create(parentID: Catalog.rootID, name: "file", kind: .file),
            payload: .init(id: mutationUUID(), size: 42, sha256: String(repeating: "a", count: 64)), createTemplateID: "new")
        _ = try await fixture.catalog.enqueue(intent)
        try await fixture.catalog.transitionOperation(key: intent.idempotencyKey, from: .queued, to: .executing)
        let observed = entry("file", identity: .init(indexNumber: .max, createdFiletime: 99))
        let result = try await fixture.catalog.commitMutation(key: intent.idempotencyKey,
            upserts: [.init(id: id, parentID: Catalog.rootID, entry: observed)], tombstones: [])
        #expect(result.items.first?.entry.objectIdentity == observed.objectIdentity)
        let reopened = try Catalog(databaseURL: fixture.url)
        #expect(try await reopened.mutationResult(key: intent.idempotencyKey)?.items.first?.entry.objectIdentity == observed.objectIdentity)
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await reopened.commitMutation(key: intent.idempotencyKey,
                upserts: [.init(id: id, parentID: Catalog.rootID, entry: self.entry("file", identity: .init(indexNumber: 3, createdFiletime: 99)))], tombstones: [])
        }
        let first = JournalIntent(itemID: id, expectedVersion: "opaque", action: .delete, baseEntry: observed)
        let changed = JournalIntent(idempotencyKey: first.idempotencyKey, itemID: id, expectedVersion: "opaque",
                                    action: .delete, baseEntry: entry("file", identity: .init(indexNumber: .max, createdFiletime: 100)))
        #expect(first.requestFingerprint != changed.requestFingerprint)
    }

    @Test func schemaFourMigrationPreservesLegacyItemsStagedScanAndHistory() async throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("schema-four.sqlite")
        let db = try SQLiteConnection(url: path, cacheKiB: 2_048)
        try db.script("""
            CREATE TABLE catalog_state(singleton INTEGER PRIMARY KEY,generation INTEGER,connection TEXT);
            INSERT INTO catalog_state VALUES(1,4,'offline');
            CREATE TABLE items(id TEXT PRIMARY KEY,parent_id TEXT,name TEXT,kind TEXT,remote_key TEXT,
                content_version TEXT,metadata_version TEXT,size INTEGER,modified_at REAL,is_deleted INTEGER);
            INSERT INTO items VALUES('root',NULL,'','directory',NULL,'','',0,NULL,0);
            INSERT INTO items VALUES('old','root','file','file',NULL,'opaque','opaque',42,NULL,0);
            CREATE TABLE scans(id TEXT PRIMARY KEY,parent_id TEXT);
            INSERT INTO scans VALUES('pending-scan','root');
            CREATE TABLE scan_entries(scan_id TEXT,name TEXT,kind TEXT,remote_key TEXT,content_version TEXT,
                metadata_version TEXT,size INTEGER,modified_at REAL,item_id TEXT);
            INSERT INTO scan_entries VALUES('pending-scan','file','file',NULL,'opaque','opaque',42,NULL,NULL);
            CREATE TABLE observed_directories(item_id TEXT PRIMARY KEY);
            CREATE TABLE offline_policy(item_id TEXT PRIMARY KEY,policy TEXT);
            CREATE TABLE operations(idempotency_key TEXT,state TEXT);
            INSERT INTO operations VALUES('retained-intent','uncertain');
            CREATE TABLE catalog_changes(sequence INTEGER PRIMARY KEY AUTOINCREMENT,item_id TEXT,old_parent_id TEXT,new_parent_id TEXT);
            CREATE TRIGGER record_item_update AFTER UPDATE ON items BEGIN
                INSERT INTO catalog_changes(item_id) VALUES(NEW.id);
            END;
            PRAGMA user_version=4;
            """)
        let migrated = try Catalog(databaseURL: path)
        #expect(try await migrated.item(id: "old")?.entry.objectIdentity == nil)
        #expect(try db.scalarText("SELECT state FROM operations") == "uncertain")
        #expect(try db.scalarInt("PRAGMA user_version") == 7)
        try await migrated.completeScan(.init(id: "pending-scan", parentID: Catalog.rootID))
        #expect(try await migrated.child(named: "file", in: Catalog.rootID)?.id == "old")
        #expect(try await migrated.generation() == 4)
        let reopened = try Catalog(databaseURL: path)
        #expect(try await reopened.item(id: "old")?.entry.objectIdentity == nil)
        // A regular file keeps its logical path identity after atomic saves,
        // including the first typed observation of a migrated legacy row.
        try await publish([RemoteEntry(name: "file", kind: .file, contentVersion: "new opaque version",
            metadataVersion: "opaque", size: 42, objectIdentity: .init(indexNumber: 8, createdFiletime: 9))], to: reopened)
        #expect(try await reopened.child(named: "file", in: Catalog.rootID)?.id == "old")
        #expect(try await reopened.item(id: "old")?.isDeleted == false)
    }

    private func entry(_ name: String, kind: ItemKind = .file, identity: RemoteObjectIdentity? = nil) -> RemoteEntry {
        RemoteEntry(name: name, kind: kind, contentVersion: "opaque", metadataVersion: "opaque", size: kind == .file ? 42 : 0,
                    objectIdentity: identity)
    }

    private func publish(_ entries: [RemoteEntry], to catalog: Catalog, parent: String = Catalog.rootID) async throws {
        let scan = try await catalog.beginScan(of: parent)
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
