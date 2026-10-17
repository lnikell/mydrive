import Testing
@testable import MyDriveCore

@Suite struct DirectoryObservationTests {
    @Test func terminalDirectoryMetadataPublishesWithoutChildChangesAndIdenticalRefreshIsQuiet() async throws {
        let f = try Fixture()
        let original = directory("folder", version: "\u{00e9}", key: "stable-folder")
        try await publish([original], to: f.catalog)
        let folder = try #require(try await f.catalog.child(named: "folder", in: Catalog.rootID))
        try await f.catalog.setOfflinePolicy(.keepAvailable, for: folder.id)
        let generation = try await f.catalog.generation(), anchor = try await f.catalog.currentChangeAnchor()
        // Canonically equivalent tokens are still different opaque wire bytes.
        let terminal = directory("folder", version: "e\u{0301}")
        let scan = try await f.catalog.beginScan(of: folder.id)
        #expect(try await f.catalog.completeScan(scan, directory: terminal) == generation + 1)
        let updated = try #require(try await f.catalog.item(id: folder.id))
        #expect(updated.entry.contentVersion.utf8.elementsEqual(terminal.contentVersion.utf8))
        #expect(updated.entry.metadataVersion.utf8.elementsEqual(terminal.metadataVersion.utf8))
        #expect(updated.entry.remoteKey == original.remoteKey)
        #expect(try await f.catalog.offlinePolicy(for: folder.id) == .keepAvailable)
        #expect(try await f.catalog.changes(since: anchor).updated.map(\.id) == [folder.id])
        #expect(try await f.catalog.changes(since: anchor, in: Catalog.rootID).updated.map(\.id) == [folder.id])
        let reopened = try Catalog(databaseURL: f.url)
        let quietAnchor = try await reopened.currentChangeAnchor()
        let repeated = try await reopened.beginScan(of: folder.id)
        #expect(try await reopened.completeScan(repeated, directory: terminal) == generation + 1)
        #expect(try await reopened.currentChangeAnchor() == quietAnchor)
    }

    @Test func terminalDirectoryAndChildrenAdvanceOneGenerationTogether() async throws {
        let f = try Fixture(), initial = directory("folder", version: "before")
        try await publish([initial], to: f.catalog)
        let folder = try #require(try await f.catalog.child(named: "folder", in: Catalog.rootID))
        let generation = try await f.catalog.generation(), anchor = try await f.catalog.currentChangeAnchor()
        let scan = try await f.catalog.beginScan(of: folder.id)
        try await f.catalog.stage([file("created.txt")], in: scan)
        #expect(try await f.catalog.completeScan(scan, directory: directory("folder", version: "after")) == generation + 1)
        let child = try #require(try await f.catalog.child(named: "created.txt", in: folder.id))
        #expect(try await f.catalog.item(id: folder.id)?.entry.contentVersion == "after")
        #expect(Set(try await f.catalog.changes(since: anchor).updated.map(\.id)) == [folder.id, child.id])
    }

    @Test func replacementMissingIdentityWrongKindAndByteDistinctNameCannotPublish() async throws {
        let f = try Fixture(), original = directory("\u{00e9}", version: "before")
        try await publish([original], to: f.catalog)
        let folder = try #require(try await f.catalog.child(named: original.name, in: Catalog.rootID))
        let generation = try await f.catalog.generation(), anchor = try await f.catalog.currentChangeAnchor()
        let invalid = [
            directory(original.name, version: "replacement", identity: .init(indexNumber: 99, createdFiletime: 100)),
            directory(original.name, version: "missing", identity: nil),
            directory(original.name, version: "zero", identity: .init(indexNumber: 1, createdFiletime: 0)),
            directory("e\u{0301}", version: "renamed"),
            RemoteEntry(name: original.name, kind: .file, contentVersion: "wrong-kind", metadataVersion: "wrong-kind",
                        objectIdentity: original.objectIdentity)
        ]
        for terminal in invalid {
            let scan = try await f.catalog.beginScan(of: folder.id)
            try await f.catalog.stage([file("unpublished.txt")], in: scan)
            await #expect(throws: CatalogError.invalidParent) { try await f.catalog.completeScan(scan, directory: terminal) }
            #expect(try await f.catalog.item(id: folder.id)?.entry == original)
            #expect(try await f.catalog.children(of: folder.id).items.isEmpty)
            #expect(try await f.catalog.generation() == generation)
            #expect(try await f.catalog.currentChangeAnchor() == anchor)
        }
    }

    @Test func childPublicationFailureRollsBackFreshParentMetadataAndItsChangeEvent() async throws {
        let f = try Fixture(), original = directory("folder", version: "before", key: "parent-key")
        try await publish([original], to: f.catalog)
        let folder = try #require(try await f.catalog.child(named: "folder", in: Catalog.rootID))
        let generation = try await f.catalog.generation(), anchor = try await f.catalog.currentChangeAnchor()
        let scan = try await f.catalog.beginScan(of: folder.id)
        // Reusing the parent remote key would form a cycle after the parent's
        // metadata update, so the entire publication must roll back.
        try await f.catalog.stage([file("cycle", key: original.remoteKey)], in: scan)
        await #expect(throws: CatalogError.invalidEntry) {
            try await f.catalog.completeScan(scan, directory: self.directory("folder", version: "after"))
        }
        #expect(try await f.catalog.item(id: folder.id)?.entry == original)
        #expect(try await f.catalog.children(of: folder.id).items.isEmpty)
        #expect(try await f.catalog.generation() == generation)
        #expect(try await f.catalog.currentChangeAnchor() == anchor)
        try await f.catalog.abandonScan(scan) // Failed publication did not consume its scan.
    }

    @Test func movingAnAncestorInvalidatesTheFrozenDirectoryPath() async throws {
        let f = try Fixture(), outer = directory("outer", version: "outer", key: "outer", identity: .init(indexNumber: 10, createdFiletime: 11))
        try await publish([outer], to: f.catalog)
        let outerID = try #require(try await f.catalog.child(named: "outer", in: Catalog.rootID)?.id)
        let inner = directory("inner", version: "before", key: "inner")
        try await publish([inner], to: f.catalog, parent: outerID)
        let innerID = try #require(try await f.catalog.child(named: "inner", in: outerID)?.id)
        let scan = try await f.catalog.beginScan(of: innerID)
        try await f.catalog.stage([file("former-path.txt")], in: scan)
        try await publish([directory("moved", version: "outer", key: "outer", identity: outer.objectIdentity)], to: f.catalog)
        let generation = try await f.catalog.generation(), anchor = try await f.catalog.currentChangeAnchor()
        await #expect(throws: CatalogError.invalidParent) {
            try await f.catalog.completeScan(scan, directory: self.directory("inner", version: "after"))
        }
        #expect(try await f.catalog.relativePath(id: innerID) == "moved/inner")
        #expect(try await f.catalog.item(id: innerID)?.entry.contentVersion == "before")
        #expect(try await f.catalog.generation() == generation)
        #expect(try await f.catalog.currentChangeAnchor() == anchor)
    }

    @Test func syntheticRootIsUnchangedAndRecursiveCaptureKeepsItsFrozenObservation() async throws {
        let f = try Fixture()
        let root = try #require(try await f.catalog.item(id: Catalog.rootID))
        let original = directory("folder", version: "before")
        let scan = try await f.catalog.beginScan()
        try await f.catalog.stage([original], in: scan)
        let remoteRoot = directory("", version: "remote-share", identity: .init(indexNumber: 100, createdFiletime: 101))
        try await f.catalog.completeScan(scan, directory: remoteRoot)
        #expect(try await f.catalog.item(id: Catalog.rootID) == root)
        let folder = try #require(try await f.catalog.child(named: "folder", in: Catalog.rootID))
        let status = try await f.catalog.prepareRecursiveDelete(intent: recursiveIntent(folder),
            rootParentIdentity: remoteRoot.objectIdentity!)
        let capture = try await f.catalog.beginScan(of: folder.id)
        _ = try await f.catalog.captureDeleteDirectory(key: status.key, scan: capture,
            directory: directory("folder", version: "after-discovery"))
        #expect(try await f.catalog.item(id: folder.id)?.entry.contentVersion == "after-discovery")
        guard case .remove(let frozen, _, _, _, _) = try #require(try await f.catalog.nextRecursiveDeleteWork(key: status.key).first)
        else { throw CatalogError.invalidTransition }
        #expect(frozen.entry == original)
        #expect(try await f.catalog.operation(key: status.key)?.intent.baseEntry == original)
    }

    private func directory(_ name: String, version: String, key: String? = nil,
                           identity: RemoteObjectIdentity? = .init(indexNumber: 1, createdFiletime: 2)) -> RemoteEntry {
        RemoteEntry(name: name, kind: .directory, remoteKey: key, contentVersion: version, metadataVersion: version,
                    objectIdentity: identity)
    }
    private func file(_ name: String, key: String? = nil) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, remoteKey: key, contentVersion: "content", metadataVersion: "metadata", size: 42,
                    objectIdentity: .init(indexNumber: 2, createdFiletime: 3))
    }
    private func publish(_ entries: [RemoteEntry], to catalog: Catalog, parent: String = Catalog.rootID) async throws {
        let scan = try await catalog.beginScan(of: parent)
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
