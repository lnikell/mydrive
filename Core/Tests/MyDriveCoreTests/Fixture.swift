import Foundation
import MyDriveCore

func fixtureDate() -> Date { Date() }

final class Fixture {
    let directory: URL
    let url: URL
    let catalog: Catalog

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mydrive-catalog-\(UUID().uuidString)")
        url = directory.appendingPathComponent("catalog.sqlite")
        catalog = try Catalog(databaseURL: url)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
