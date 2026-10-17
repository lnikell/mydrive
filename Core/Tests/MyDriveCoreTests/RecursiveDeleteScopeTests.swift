import Testing
@testable import MyDriveCore

@Suite struct RecursiveDeleteScopeTests {
    @Test func movedOutCapturedDirectoryKeepsItsLeafIdentityWhenOldFrozenPathsBecomeAbsent() async throws {
        let f = try Fixture()
        let rootEntry = directory("tree", 1)
        try await publish([rootEntry], parent: Catalog.rootID, in: f.catalog)
        let root = try #require(try await f.catalog.child(named: "tree", in: Catalog.rootID))
        let status = try await f.catalog.prepareRecursiveDelete(intent: recursiveIntent(root),
            rootParentIdentity: .init(indexNumber: 900, createdFiletime: 901))
        let innerEntry = directory("inner", 10)
        let first = try await f.catalog.beginScan(of: root.id)
        try await f.catalog.stage([innerEntry], in: first)
        _ = try await f.catalog.captureDeleteDirectory(key: status.key, scan: first, directory: rootEntry)
        let inner = try #require(try await f.catalog.child(named: "inner", in: root.id))
        let leafEntry = RemoteEntry(name: "leaf", kind: .file, contentVersion: "bytes", metadataVersion: "metadata", size: 42,
                                    objectIdentity: .init(indexNumber: 20, createdFiletime: 21))
        let second = try await f.catalog.beginScan(of: inner.id)
        try await f.catalog.stage([leafEntry], in: second)
        _ = try await f.catalog.captureDeleteDirectory(key: status.key, scan: second, directory: innerEntry)
        let leafWork = try #require(try await f.catalog.nextRecursiveDeleteWork(key: status.key).first)
        let leaf = try #require(try await f.catalog.child(named: "leaf", in: inner.id))
        let movedEntry = directory("moved-out", 10)
        let move = JournalIntent(itemID: inner.id, expectedVersion: innerEntry.contentVersion,
                                 action: .move(parentID: Catalog.rootID, name: "moved-out"))
        _ = try await f.catalog.enqueue(move)
        try await f.catalog.transitionOperation(key: move.idempotencyKey, from: .queued, to: .executing)
        try await f.catalog.commitMutation(key: move.idempotencyKey,
            upserts: [.init(id: inner.id, parentID: Catalog.rootID, entry: movedEntry)], tombstones: [])
        let anchor = try await f.catalog.currentChangeAnchor()
        // The whole original subtree is now outside. Leaf parentID/name/object
        // identity stayed equal, so only the full exact path detects this move.
        let (leafID, leafKey) = try await childOperation(leafWork, in: f.catalog)
        try await f.catalog.recordRecursiveDeleteProgress(key: status.key,
            updates: [.bindOperation(itemID: leafID, key: leafKey), .removed(itemID: leafID, key: leafKey)])
        #expect(try await f.catalog.item(id: leaf.id)?.isDeleted == false)
        #expect(try await f.catalog.relativePath(id: leaf.id) == "moved-out/leaf")
        #expect(try await f.catalog.mutationResult(key: leafKey)?.tombstones.isEmpty == true)
        for _ in 0..<2 {
            let work = try #require(try await f.catalog.nextRecursiveDeleteWork(key: status.key).first)
            let (id, key) = try await childOperation(work, in: f.catalog)
            try await f.catalog.recordRecursiveDeleteProgress(key: status.key,
                updates: [.bindOperation(itemID: id, key: key), .removed(itemID: id, key: key)])
        }
        #expect(try await f.catalog.item(id: root.id)?.isDeleted == true)
        #expect(try await f.catalog.item(id: inner.id)?.isDeleted == false)
        #expect(try await f.catalog.item(id: leaf.id)?.isDeleted == false)
        #expect(try await f.catalog.changes(since: anchor).deletedIDs == [root.id])
    }

    @Test func nestedFrontierAndScopeRemainFrozenAcrossRestartAndDirectoryTimestampChanges() async throws {
        let f = try Fixture()
        let outerEntry = directory("outside", 100)
        try await publish([outerEntry], parent: Catalog.rootID, in: f.catalog)
        let outer = try #require(try await f.catalog.child(named: "outside", in: Catalog.rootID))
        let selectedEntry = directory("selected", 200)
        try await publish([selectedEntry], parent: outer.id, in: f.catalog)
        let selected = try #require(try await f.catalog.child(named: "selected", in: outer.id))
        let intent = JournalIntent(itemID: selected.id, expectedVersion: selectedEntry.contentVersion, action: .deleteTree,
            sourcePath: "outside/selected", baseEntry: selectedEntry)
        let status = try await f.catalog.prepareRecursiveDelete(intent: intent, rootParentIdentity: outerEntry.objectIdentity!)
        #expect(status.scope.rootPath == "outside/selected")
        #expect(status.scope.parentPath == "outside")
        #expect(status.scope.rootIdentity == selectedEntry.objectIdentity)
        #expect(status.scope.parentIdentity == outerEntry.objectIdentity)
        let innerEntry = directory("inner", 300)
        let first = try await f.catalog.beginScan(of: selected.id)
        try await f.catalog.stage([innerEntry], in: first)
        _ = try await f.catalog.captureDeleteDirectory(key: status.key, scan: first, directory: selectedEntry)
        let reopened = try Catalog(databaseURL: f.url)
        let frontier = try await reopened.nextRecursiveDeleteWork(key: status.key, limit: 1)
        guard case .capture(let inner, let path, let scope) = try #require(frontier.first) else {
            throw CatalogError.invalidEntry
        }
        #expect(path == "outside/selected/inner")
        #expect(scope == status.scope)
        let leaf = RemoteEntry(name: "leaf", kind: .file, contentVersion: "bytes", metadataVersion: "metadata", size: 42,
                               objectIdentity: .init(indexNumber: 400, createdFiletime: 401))
        let scan = try await reopened.beginScan(of: inner.id)
        try await reopened.stage([leaf], in: scan)
        _ = try await reopened.captureDeleteDirectory(key: status.key, scan: scan, directory: innerEntry)
        let leafWork = try #require(try await reopened.nextRecursiveDeleteWork(key: status.key, limit: 1).first)
        guard case .remove(let leafItem, let leafPath, let parent, _, let frozenScope) = leafWork else {
            throw CatalogError.invalidEntry
        }
        #expect(leafPath == "outside/selected/inner/leaf")
        #expect(parent == innerEntry.objectIdentity)
        #expect(frozenScope == status.scope)
        let (leafID, leafKey) = try await childOperation(leafWork, in: reopened)
        #expect(leafID == leafItem.id)
        try await reopened.recordRecursiveDeleteProgress(key: status.key,
            updates: [.bindOperation(itemID: leafID, key: leafKey), .removed(itemID: leafID, key: leafKey)])
        // Child removals may legitimately update the directory's opaque mtime
        // token. The immutable snapshot and stable object identity stay separate.
        let changed = RemoteEntry(name: "inner", kind: .directory, contentVersion: "after-own-child-removal", metadataVersion: "new-mtime",
                                  objectIdentity: innerEntry.objectIdentity)
        try await publish([changed], parent: selected.id, in: reopened)
        let innerWork = try #require(try await reopened.nextRecursiveDeleteWork(key: status.key).first)
        if case .remove(let frozenInner, _, let frozenParent, _, let sameScope) = innerWork {
            #expect(frozenInner.entry.contentVersion == innerEntry.contentVersion)
            #expect(frozenInner.entry.objectIdentity == changed.objectIdentity)
            #expect(frozenParent == selectedEntry.objectIdentity)
            #expect(sameScope == status.scope)
        } else { Issue.record("Captured child directory was not returned in postorder") }
        let (innerID, innerKey) = try await childOperation(innerWork, in: reopened)
        try await reopened.recordRecursiveDeleteProgress(key: status.key,
            updates: [.bindOperation(itemID: innerID, key: innerKey), .removed(itemID: innerID, key: innerKey)])
        let final = try await reopened.nextRecursiveDeleteWork(key: status.key)
        #expect(final.count == 1)
        if case .remove(let item, _, let parent, _, let scope) = try #require(final.first) {
            #expect(item.id == selected.id)
            #expect(parent == outerEntry.objectIdentity)
            #expect(scope == status.scope)
        }
        #expect(try await reopened.item(id: outer.id)?.isDeleted == false)
        #expect(try await reopened.operation(key: status.key)?.state != .completed)
    }

    @Test func bindingCannotReplaceAnAlreadyDurableUncertainChildOperation() async throws {
        let f = try Fixture()
        let entry = directory("tree", 1)
        try await publish([entry], parent: Catalog.rootID, in: f.catalog)
        let root = try #require(try await f.catalog.child(named: "tree", in: Catalog.rootID))
        let status = try await f.catalog.prepareRecursiveDelete(intent: recursiveIntent(root),
            rootParentIdentity: .init(indexNumber: 800, createdFiletime: 801))
        let scan = try await f.catalog.beginScan(of: root.id)
        _ = try await f.catalog.captureDeleteDirectory(key: status.key, scan: scan, directory: entry)
        let work = try #require(try await f.catalog.nextRecursiveDeleteWork(key: status.key).first)
        let (id, key) = try await childOperation(work, in: f.catalog)
        try await f.catalog.recordRecursiveDeleteProgress(key: status.key, updates: [.bindOperation(itemID: id, key: key)])
        try await f.catalog.transitionOperation(key: key, from: .executing, to: .uncertain)
        let otherBase = RemoteEntry(name: "tree", kind: .directory, contentVersion: "different", metadataVersion: "different",
                                    objectIdentity: entry.objectIdentity)
        let another = JournalIntent(itemID: id, expectedVersion: otherBase.contentVersion, action: .delete,
                                    sourcePath: "tree", baseEntry: otherBase)
        _ = try await f.catalog.enqueue(another)
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await f.catalog.recordRecursiveDeleteProgress(key: status.key,
                updates: [.bindOperation(itemID: id, key: another.idempotencyKey)])
        }
        #expect(try await f.catalog.operation(key: key)?.state == .uncertain)
    }

    private func directory(_ name: String, _ index: UInt64) -> RemoteEntry {
        .init(name: name, kind: .directory, contentVersion: "v\(index)", metadataVersion: "m\(index)",
              objectIdentity: .init(indexNumber: index, createdFiletime: index + 1))
    }
    private func publish(_ entries: [RemoteEntry], parent: String, in catalog: Catalog) async throws {
        let scan = try await catalog.beginScan(of: parent)
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
