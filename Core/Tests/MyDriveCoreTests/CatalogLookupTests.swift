import Testing
@testable import MyDriveCore

@Suite struct CatalogLookupTests {
    @Test func lookupIsExactAndExcludesTombstonesAcrossRestart() async throws {
        let fixture = try Fixture()
        let nfc = "caf\u{e9}"
        let nfd = "cafe\u{301}"
        let scan = try await fixture.catalog.beginScan()
        try await fixture.catalog.stage([nfc, nfd, "removed"].map {
            RemoteEntry(name: $0, kind: .file, contentVersion: "v", metadataVersion: "m")
        }, in: scan)
        try await fixture.catalog.completeScan(scan)
        let a = try #require(try await fixture.catalog.child(named: nfc, in: Catalog.rootID))
        let b = try #require(try await fixture.catalog.child(named: nfd, in: Catalog.rootID))
        #expect(a.id != b.id)
        #expect(Array(a.entry.name.utf8) == Array(nfc.utf8))
        #expect(Array(b.entry.name.utf8) == Array(nfd.utf8))
        let second = try await fixture.catalog.beginScan()
        try await fixture.catalog.stage([a.entry, b.entry], in: second)
        try await fixture.catalog.completeScan(second)
        let reopened = try Catalog(databaseURL: fixture.url)
        #expect(try await reopened.child(named: "removed", in: Catalog.rootID) == nil)
        #expect(try await reopened.child(named: nfd, in: Catalog.rootID)?.id == b.id)
        await #expect(throws: CatalogError.invalidParent) { try await reopened.child(named: "anything", in: a.id) }
    }

    @Test func ambiguousLiveNamesNeverChooseAnArbitraryIdentity() async throws {
        let fixture = try Fixture()
        let scan = try await fixture.catalog.beginScan()
        try await fixture.catalog.stage([RemoteEntry(name: "same", kind: .file, contentVersion: "v", metadataVersion: "m")], in: scan)
        try await fixture.catalog.completeScan(scan)
        let database = try SQLiteConnection(url: fixture.url, cacheKiB: 256)
        try database.execute("""
            INSERT INTO items(id,parent_id,name,kind,content_version,metadata_version,size,is_deleted)
            VALUES ('ambiguous-other','root','same','file','v','m',0,0)
            """)
        await #expect(throws: CatalogError.invalidEntry) { try await fixture.catalog.child(named: "same", in: Catalog.rootID) }
    }
}
