import Testing
@testable import MyDriveCore

@Suite struct LibraryCountsTests {
    @Test func dailyTotalsDeduplicateVerifiedContentAndSurviveRestart() async throws {
        let fixture = try Fixture(), now = fixtureDate()
        try await fixture.catalog.recordTransfer(itemID: "file", version: "v1", upload: true, bytes: 42, date: now)
        try await fixture.catalog.recordTransfer(itemID: "file", version: "v1", upload: true, bytes: 42, date: now)
        try await fixture.catalog.recordTransfer(itemID: "file", version: "v1", upload: false, bytes: 42, date: now)
        let reopened = try Catalog(databaseURL: fixture.url)
        var totals = try await reopened.transferTotals(date: now)
        #expect(totals.files == 2 && totals.uploaded == 42 && totals.downloaded == 42)
        try await reopened.recordTransfer(itemID: "file", version: "v2", upload: true, bytes: 100, date: now)
        totals = try await fixture.catalog.transferTotals(date: now)
        #expect(totals.files == 3 && totals.uploaded == 142 && totals.downloaded == 42)
    }

    @Test func repeatedHydrationsCountSeparateFetchesButNotReceiptReplay() async throws {
        let fixture = try Fixture(), now = fixtureDate()
        let first = "fetch:10801CB9-8C3A-41B0-A4EC-34BEF74B3E9D"
        let second = "fetch:F2FF7E56-A3B8-4B64-9A89-382DE8AF6D20"
        try await fixture.catalog.recordTransfer(itemID: "same-revision", version: first, upload: false, bytes: 720000, date: now)
        let reopened = try Catalog(databaseURL: fixture.url)
        try await reopened.recordTransfer(itemID: "same-revision", version: first, upload: false, bytes: 720000, date: now)
        try await reopened.recordTransfer(itemID: "same-revision", version: second, upload: false, bytes: 720000, date: now)
        let totals = try await fixture.catalog.transferTotals(date: now)
        #expect(totals.files == 2 && totals.downloaded == 1440000 && totals.uploaded == 0)
    }

    @Test func countsRespectInheritedSelectionsAndRemovedAncestors() async throws {
        let fixture = try Fixture(), catalog = fixture.catalog
        func publish(_ entries: [RemoteEntry], parent: String = Catalog.rootID) async throws {
            let scan = try await catalog.beginScan(of: parent)
            try await catalog.stage(entries, in: scan)
            try await catalog.completeScan(scan)
        }
        let folder = RemoteEntry(name: "Folder", kind: .directory, contentVersion: "v1", metadataVersion: "v1")
        let file = RemoteEntry(name: "File", kind: .file, contentVersion: "v1", metadataVersion: "v1", size: 42)
        try await publish([folder, file])
        let parent = try #require(try await catalog.children().items.first { $0.entry.kind == .directory }?.id)
        try await publish([file], parent: parent)
        var counts = try await catalog.libraryCounts()
        #expect(counts.onDemandFiles == 2 && counts.explicitSelections == 0)
        try await catalog.setOfflinePolicy(.keepAvailable, for: parent)
        counts = try await catalog.libraryCounts()
        #expect(counts.onDemandFiles == 1 && counts.explicitSelections == 1)
        try await catalog.setOfflinePolicy(.keepAvailable, for: Catalog.rootID)
        counts = try await catalog.libraryCounts()
        #expect(counts.onDemandFiles == 0 && counts.explicitSelections == 2)
        try await catalog.setOfflinePolicy(.onDemand, for: Catalog.rootID)
        try await publish([file])
        counts = try await catalog.libraryCounts()
        #expect(counts.onDemandFiles == 1 && counts.explicitSelections == 0)
    }

    @Test func dailyTotalsSaturateRatherThanPromotingToFloatingPoint() async throws {
        let fixture = try Fixture(), date = fixtureDate()
        try await fixture.catalog.recordTransfer(itemID: "first", version: "v1", upload: true, bytes: .max, date: date)
        try await fixture.catalog.recordTransfer(itemID: "second", version: "v1", upload: true, bytes: 100, date: date)
        let totals = try await fixture.catalog.transferTotals(date: date)
        #expect(totals.uploaded == .max && totals.files == 2 && totals.downloaded == 0)
    }
}
