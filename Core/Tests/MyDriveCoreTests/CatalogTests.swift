import Testing
@testable import MyDriveCore

@Suite struct CatalogTests {
    @Test func usesVerifiedDurabilityAndBoundedCache() async throws {
        let fixture = try Fixture()
        let settings = try await fixture.catalog.settings()
        #expect(settings.journalMode == "wal")
        #expect(settings.synchronous == 2)
        #expect(settings.cacheSizeKiB == 2_048)
    }

    @Test func interruptedScanCannotDeletePublishedItems() async throws {
        let fixture = try Fixture()
        try await publish([file("a"), file("b")], to: fixture.catalog)
        let scan = try await fixture.catalog.beginScan()
        try await fixture.catalog.stage([file("a")], in: scan)
        let before = try await fixture.catalog.children()
        #expect(before.items.map(\.entry.name) == ["a", "b"])
        let reopened = try Catalog(databaseURL: fixture.url)
        let afterRestart = try await reopened.children()
        #expect(afterRestart.items.map(\.entry.name) == ["a", "b"])
        let replacement = try await reopened.beginScan()
        await #expect(throws: CatalogError.invalidScan) {
            try await reopened.completeScan(scan)
        }
        try await reopened.abandonScan(replacement)
        #expect(try await reopened.children().items.count == 2)
    }

    @Test func completeScanPublishesAdditionsAndTombstonesTogether() async throws {
        let fixture = try Fixture()
        try await publish([file("a"), file("b")], to: fixture.catalog)
        let old = try await fixture.catalog.children().items
        let removedID = try #require(old.first { $0.entry.name == "b" }?.id)
        try await publish([file("a"), file("c")], to: fixture.catalog)
        #expect(try await fixture.catalog.children().items.map(\.entry.name) == ["a", "c"])
        #expect(try await fixture.catalog.item(id: removedID)?.isDeleted == true)
    }

    @Test func stableRemoteIdentityPreservesPinAcrossRenameAndRestart() async throws {
        let fixture = try Fixture()
        try await publish([file("before", key: "stable-123")], to: fixture.catalog)
        let id = try #require(try await fixture.catalog.children().items.first?.id)
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: id)
        try await publish([file("after", key: "stable-123")], to: fixture.catalog)
        let reopened = try Catalog(databaseURL: fixture.url)
        let item = try #require(try await reopened.children().items.first)
        #expect(item.id == id)
        #expect(item.entry.name == "after")
        #expect(try await reopened.offlinePolicy(for: id) == .keepAvailable)
        try await reopened.clearOfflineSelections()
        #expect(try await reopened.offlinePolicy(for: id) == .onDemand)
        #expect(try await reopened.item(id: id)?.isDeleted == false)
    }

    @Test func folderOfflineSelectionIsInherited() async throws {
        let fixture = try Fixture()
        try await publish([RemoteEntry(name: "folder", kind: .directory, contentVersion: "v1", metadataVersion: "v1")], to: fixture.catalog)
        let folder = try #require(try await fixture.catalog.children().items.first)
        let scan = try await fixture.catalog.beginScan(of: folder.id)
        try await fixture.catalog.stage([file("child")], in: scan)
        try await fixture.catalog.completeScan(scan)
        let child = try #require(try await fixture.catalog.children(of: folder.id).items.first)
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: folder.id)
        #expect(try await fixture.catalog.offlinePolicy(for: child.id) == .keepAvailable)
    }

    @Test func boundedKeysetPagesInvalidateAfterPublication() async throws {
        let fixture = try Fixture()
        try await publish([file("c"), file("a"), file("b")], to: fixture.catalog)
        let first = try await fixture.catalog.children(limit: 2)
        #expect(first.items.map(\.entry.name) == ["a", "b"])
        let cursor = try #require(first.nextCursor)
        let last = try await fixture.catalog.children(after: cursor, limit: 2)
        #expect(last.items.map(\.entry.name) == ["c"])
        #expect(last.nextCursor == nil)
        try await publish([file("a"), file("b"), file("c"), file("d")], to: fixture.catalog)
        await #expect(throws: CatalogError.staleCursor) {
            try await fixture.catalog.children(after: cursor, limit: 2)
        }
        await #expect(throws: CatalogError.invalidPageSize) {
            try await fixture.catalog.children(limit: 1_001)
        }
    }

    @Test func failedBatchRollsBackEveryEntry() async throws {
        let fixture = try Fixture()
        let scan = try await fixture.catalog.beginScan()
        do {
            try await fixture.catalog.stage([file("duplicate"), file("duplicate")], in: scan)
            Issue.record("Expected duplicate-name constraint to fail")
        } catch CatalogError.sqlite { }
        try await fixture.catalog.stage([file("valid")], in: scan)
        try await fixture.catalog.completeScan(scan)
        #expect(try await fixture.catalog.children().items.map(\.entry.name) == ["valid"])
    }

    @Test func identicalRefreshPreservesGenerationAndCursor() async throws {
        let fixture = try Fixture()
        let entries = [file("a", key: "a"), file("b", key: "b")]
        try await publish(entries, to: fixture.catalog)
        let first = try await fixture.catalog.children(limit: 1)
        let cursor = try #require(first.nextCursor)
        try await publish(entries, to: fixture.catalog)
        let last = try await fixture.catalog.children(after: cursor, limit: 1)
        #expect(last.generation == first.generation)
        #expect(last.items.map(\.entry.name) == ["b"])
    }

    @Test func ancestorRemoteKeyCannotCreateCatalogCycle() async throws {
        let fixture = try Fixture()
        let folder = RemoteEntry(name: "folder", kind: .directory, remoteKey: "folder-key", contentVersion: "v1", metadataVersion: "v1")
        try await publish([folder], to: fixture.catalog)
        let item = try #require(try await fixture.catalog.children().items.first)
        let scan = try await fixture.catalog.beginScan(of: item.id)
        try await fixture.catalog.stage([folder], in: scan)
        await #expect(throws: CatalogError.invalidEntry) { try await fixture.catalog.completeScan(scan) }
        #expect(try await fixture.catalog.item(id: item.id)?.parentID == Catalog.rootID)
    }

    @Test func pathAndOfflinePolicyFollowStableIdentityAcrossMove() async throws {
        let fixture = try Fixture()
        let directory = RemoteEntry(name: "folder", kind: .directory, remoteKey: "folder", contentVersion: "v1", metadataVersion: "v1")
        try await publish([directory, file("before", key: "document")], to: fixture.catalog)
        let items = try await fixture.catalog.children().items
        let document = try #require(items.first { $0.entry.name == "before" })
        let folder = try #require(items.first { $0.entry.name == "folder" })
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: document.id)
        let scan = try await fixture.catalog.beginScan(of: folder.id)
        try await fixture.catalog.stage([file("after", key: "document")], in: scan)
        try await fixture.catalog.completeScan(scan)
        #expect(try await fixture.catalog.relativePath(id: document.id) == "folder/after")
        #expect(try await fixture.catalog.relativePath(id: Catalog.rootID) == "")
        #expect(try await fixture.catalog.offlineSelections(limit: 1).first?.id == document.id)
        #expect(try await fixture.catalog.offlinePolicy(for: document.id) == .keepAvailable)
    }

    @Test func completedEmptyScanAndRemovedSubtreeRemainUnambiguous() async throws {
        let fixture = try Fixture()
        #expect(try await fixture.catalog.hasCompletedScan(of: Catalog.rootID) == false)
        try await publish([], to: fixture.catalog)
        #expect(try await fixture.catalog.hasCompletedScan(of: Catalog.rootID))
        let directory = RemoteEntry(name: "folder", kind: .directory, remoteKey: "folder", contentVersion: "v1", metadataVersion: "v1")
        try await publish([directory], to: fixture.catalog)
        let folder = try #require(try await fixture.catalog.children().items.first)
        let scan = try await fixture.catalog.beginScan(of: folder.id)
        try await fixture.catalog.stage([file("child")], in: scan)
        try await fixture.catalog.completeScan(scan)
        let child = try #require(try await fixture.catalog.children(of: folder.id).items.first)
        #expect(try await fixture.catalog.knownItems().count == 2)
        try await publish([], to: fixture.catalog)
        #expect(try await fixture.catalog.knownItems().isEmpty)
        #expect(try await fixture.catalog.item(id: child.id)?.isDeleted == true)
        #expect(try await fixture.catalog.relativePath(id: child.id) == nil)
    }

    @Test func replacingDirectoryWithFileRetiresTheWholeOldSubtree() async throws {
        let fixture = try Fixture()
        let directory = RemoteEntry(name: "docs", kind: .directory, contentVersion: "v1", metadataVersion: "v1")
        try await publish([directory], to: fixture.catalog)
        let oldID = try #require(try await fixture.catalog.children().items.first?.id)
        let nested = try await fixture.catalog.beginScan(of: oldID)
        try await fixture.catalog.stage([file("old.txt")], in: nested)
        try await fixture.catalog.completeScan(nested)
        let childID = try #require(try await fixture.catalog.children(of: oldID).items.first?.id)
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: oldID)

        try await publish([file("docs")], to: fixture.catalog)
        let replacement = try #require(try await fixture.catalog.children().items.first)
        #expect(replacement.id != oldID)
        #expect(replacement.entry.kind == .file)
        #expect(try await fixture.catalog.item(id: oldID)?.isDeleted == true)
        #expect(try await fixture.catalog.item(id: childID)?.isDeleted == true)
        #expect(try await fixture.catalog.relativePath(id: childID) == nil)
        #expect(try await fixture.catalog.knownItems().map(\.id) == [replacement.id])
        #expect(try await fixture.catalog.offlinePolicy(for: replacement.id) == .onDemand)
        #expect(try await fixture.catalog.relativePath(id: replacement.id) == "docs")
    }

    @Test func replacingFileWithDirectoryStartsWithNewIdentityAndNoInheritedSelection() async throws {
        let fixture = try Fixture()
        try await publish([file("docs")], to: fixture.catalog)
        let oldID = try #require(try await fixture.catalog.children().items.first?.id)
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: oldID)
        let directory = RemoteEntry(name: "docs", kind: .directory, contentVersion: "v2", metadataVersion: "v2")
        try await publish([directory], to: fixture.catalog)
        let replacement = try #require(try await fixture.catalog.children().items.first)
        #expect(replacement.id != oldID)
        #expect(try await fixture.catalog.item(id: oldID)?.isDeleted == true)
        #expect(try await fixture.catalog.offlinePolicy(for: replacement.id) == .onDemand)
        #expect(try await fixture.catalog.hasCompletedScan(of: replacement.id) == false)
        #expect(try await fixture.catalog.relativePath(id: replacement.id) == "docs")
    }

    @Test func directoryMovedOutOfRemovedParentKeepsItsKnownChildren() async throws {
        let fixture = try Fixture()
        let old = RemoteEntry(name: "old", kind: .directory, remoteKey: "old", contentVersion: "v1", metadataVersion: "v1")
        try await publish([old], to: fixture.catalog)
        let oldID = try #require(try await fixture.catalog.children().items.first?.id)
        let nested = RemoteEntry(name: "nested", kind: .directory, remoteKey: "nested", contentVersion: "v1", metadataVersion: "v1")
        let oldScan = try await fixture.catalog.beginScan(of: oldID)
        try await fixture.catalog.stage([nested], in: oldScan)
        try await fixture.catalog.completeScan(oldScan)
        let nestedID = try #require(try await fixture.catalog.children(of: oldID).items.first?.id)
        let nestedScan = try await fixture.catalog.beginScan(of: nestedID)
        try await fixture.catalog.stage([file("child")], in: nestedScan)
        try await fixture.catalog.completeScan(nestedScan)
        let childID = try #require(try await fixture.catalog.children(of: nestedID).items.first?.id)
        let moved = RemoteEntry(name: "moved", kind: .directory, remoteKey: "nested", contentVersion: "v1", metadataVersion: "v1")
        try await publish([moved], to: fixture.catalog)
        #expect(try await fixture.catalog.relativePath(id: childID) == "moved/child")
        #expect(try await fixture.catalog.knownItems().count == 2)
    }

    @Test func journalReplayRequiresResolutionOfUncertainOutcome() async throws {
        let fixture = try Fixture()
        try await publish([file("document")], to: fixture.catalog)
        let item = try #require(try await fixture.catalog.children().items.first)
        let intent = JournalIntent(itemID: item.id, expectedVersion: "v1", action: .rename(name: "renamed"))
        let queued = try await fixture.catalog.enqueue(intent)
        #expect(queued == (try await fixture.catalog.enqueue(intent)))
        try await fixture.catalog.transitionOperation(key: intent.idempotencyKey, from: .queued, to: .executing)
        let reopened = try Catalog(databaseURL: fixture.url)
        try await reopened.recoverInterruptedOperations()
        let recovered = try #require(try await reopened.replayableOperations().first)
        #expect(recovered.state == .uncertain)
        #expect(recovered.attemptCount == 1)
        await #expect(throws: CatalogError.invalidTransition) {
            try await reopened.transitionOperation(key: intent.idempotencyKey, from: .uncertain, to: .executing)
        }
        let resolved = try await reopened.transitionOperation(key: intent.idempotencyKey, from: .uncertain, to: .completed)
        #expect(resolved.state == .completed)
        #expect(try await reopened.replayableOperations().isEmpty)
        #expect(try await reopened.transitionOperation(key: intent.idempotencyKey, from: .uncertain, to: .completed) == resolved)
    }

    @Test func journalRejectsIdempotencyKeyReuseForDifferentIntent() async throws {
        let fixture = try Fixture()
        try await publish([file("document")], to: fixture.catalog)
        let item = try #require(try await fixture.catalog.children().items.first)
        let original = JournalIntent(itemID: item.id, expectedVersion: nil, action: .delete)
        let key = original.idempotencyKey
        _ = try await fixture.catalog.enqueue(original)
        let different = JournalIntent(idempotencyKey: key, itemID: item.id, expectedVersion: nil, action: .rename(name: "other"))
        await #expect(throws: CatalogError.idempotencyConflict) { try await fixture.catalog.enqueue(different) }
    }

    @Test func connectionStatePersistsWithoutChangingFiles() async throws {
        let fixture = try Fixture()
        try await publish([file("document")], to: fixture.catalog)
        try await fixture.catalog.setConnectionState(.offline)
        let reopened = try Catalog(databaseURL: fixture.url)
        #expect(try await reopened.connectionState() == .offline)
        #expect(try await reopened.children().items.count == 1)
    }

    @Test func offlineSelectionChangesAdvanceGenerationAndClearSubtrees() async throws {
        let fixture = try Fixture()
        let folder = RemoteEntry(name: "folder", kind: .directory, contentVersion: "v1", metadataVersion: "v1")
        try await publish([folder], to: fixture.catalog)
        let id = try #require(try await fixture.catalog.children().items.first?.id)
        let scan = try await fixture.catalog.beginScan(of: id)
        try await fixture.catalog.stage([file("child")], in: scan)
        try await fixture.catalog.completeScan(scan)
        let childID = try #require(try await fixture.catalog.children(of: id).items.first?.id)
        let before = try await fixture.catalog.generation()
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: childID)
        #expect(try await fixture.catalog.generation() == before + 1)
        try await fixture.catalog.setOfflinePolicy(.keepAvailable, for: childID)
        #expect(try await fixture.catalog.generation() == before + 1)
        try await fixture.catalog.clearOfflineSelections(in: id)
        #expect(try await fixture.catalog.generation() == before + 2)
        #expect(try await fixture.catalog.offlinePolicy(for: childID) == .onDemand)
        try await fixture.catalog.clearOfflineSelections(in: id)
        #expect(try await fixture.catalog.generation() == before + 2)
    }

    private func file(_ name: String, key: String? = nil) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, remoteKey: key, contentVersion: "v1", metadataVersion: "v1", size: 42)
    }

    private func publish(_ entries: [RemoteEntry], to catalog: Catalog) async throws {
        let scan = try await catalog.beginScan()
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
