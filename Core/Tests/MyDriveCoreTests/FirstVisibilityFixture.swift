import Foundation
@testable import MyDriveCore

// Separate Foundation from the CLT Testing module's missing overlay. These
// connections touch only each test's owned local SQLite fixture.
func visibilitySQL(_ fixture: Fixture, _ sql: String) throws {
    try SQLiteConnection(url: fixture.url, cacheKiB: 2_048).script(sql)
}

func visibilityQuery(_ fixture: Fixture, _ sql: String, _ values: [SQLValue] = [], column: Int32 = 0) throws -> [String] {
    try SQLiteConnection(url: fixture.url, cacheKiB: 2_048).statement(sql, values) { statement in
        var result: [String] = []
        while try statement.step() { result.append(statement.text(column)) }
        return result
    }
}

func visibilityMeasuredComplete(_ fixture: Fixture, _ scan: CatalogScan) async throws {
    let clock = ContinuousClock(), start = clock.now
    try await fixture.catalog.completeScan(scan)
    let elapsed = start.duration(to: clock.now).components
    let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path + "-wal")
    print("LOCAL synthetic5200-row terminal milliseconds=\(milliseconds) walBytesAfter=\(attributes[.size] ?? 0); includes assigned-index insertion/deletion, not native/startup/RSS qualification")
}

func visibilityMeasuredReopen(_ fixture: Fixture) throws -> Catalog {
    let clock = ContinuousClock(), start = clock.now
    let catalog = try Catalog(databaseURL: fixture.url)
    let elapsed = start.duration(to: clock.now).components
    let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path + "-wal")
    print("LOCAL synthetic10000-row v8-to-v9 visibility-migration reopen milliseconds=\(milliseconds) walBytesAfter=\(attributes[.size] ?? 0); not native/startup/RSS qualification")
    return catalog
}
