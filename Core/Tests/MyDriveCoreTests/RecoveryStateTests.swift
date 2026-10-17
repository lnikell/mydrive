import Testing
@testable import MyDriveCore

@Suite struct RecoveryStateTests {
    @Test func cleanupRequiresEveryJournalRecordToBeCompleted() async throws {
        let fixture = try Fixture()
        #expect(try await fixture.catalog.hasUnfinishedMutations() == false)
        let scan = try await fixture.catalog.beginScan()
        let entry = RemoteEntry(name: "file", kind: .file, contentVersion: "v", metadataVersion: "m")
        try await fixture.catalog.stage([entry], in: scan)
        try await fixture.catalog.completeScan(scan)
        let item = try #require(try await fixture.catalog.children().items.first)
        let intent = JournalIntent(itemID: item.id, expectedVersion: "v", action: .delete)
        _ = try await fixture.catalog.enqueue(intent)
        #expect(try await fixture.catalog.hasUnfinishedMutations())
        _ = try await fixture.catalog.transitionOperation(key: intent.idempotencyKey, from: .queued, to: .executing)
        _ = try await fixture.catalog.transitionOperation(key: intent.idempotencyKey, from: .executing, to: .failed)
        #expect(try await fixture.catalog.replayableOperations().isEmpty)
        #expect(try await fixture.catalog.hasUnfinishedMutations())
        let database = try SQLiteConnection(url: fixture.url, cacheKiB: 256)
        try database.execute("UPDATE operations SET state = 'unrecognized-future-state'")
        #expect(try await fixture.catalog.hasUnfinishedMutations())
        try database.execute("UPDATE operations SET state = 'completed'")
        #expect(try await fixture.catalog.hasUnfinishedMutations() == false)
    }
}
