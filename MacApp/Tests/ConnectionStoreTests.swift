import Foundation
import MyDriveCore

private struct StoreFailure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw StoreFailure(message: message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw StoreFailure(message: "A disallowed storage operation succeeded")
}

@main struct ConnectionStoreTests {
    static func settings(_ id: String, name: String = "Test") -> ConnectionSettings {
        ConnectionSettings(domainID: id, displayName: name, host: "nas.local:445", share: "shared", username: "test")
    }

    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("connections"), store = ConnectionStore(root: root)
        let a = settings("a64b4560-8c04-4dde-819e-2125e8cfe746", name: "A")
        let b = settings("1d12a430-7c84-46ab-83ce-d702d4b371e1", name: "B")
        try require(try store.load().connections.isEmpty, "Missing root was not empty")
        try require(try store.existingSettings(for: a.id) == nil, "Missing settings returned a value")
        try require(!FileManager.default.fileExists(atPath: root.path), "Read created a directory")
        for id in ["../escape", "", "UPPER", a.id.uppercased(), "{" + a.id + "}"] {
            try rejects { _ = try store.folder(for: id, create: true) }
        }
        try store.save(a); try store.save(b); try store.save(settings("unas-test"))
        let restarted = ConnectionStore(root: root)
        try require(Set(try restarted.load().connections.map(\.id)) == [a.id, b.id, "unas-test"], "Restart lost immutable IDs or legacy migration")
        try require(try restarted.folder(for: a.id) != restarted.folder(for: b.id), "Drives share a directory")
        print("PASS stable UUID/legacy records, restart, path guards and read-only missing lookup")

        var renamed = a; renamed.displayName = "Renamed"
        try store.save(renamed)
        for field in ["host", "share", "user"] {
            var changed = renamed
            if field == "host" { changed.host = "another.local" }
            if field == "share" { changed.share = "another" }
            if field == "user" { changed.username = "another" }
            try rejects { try store.save(changed) }
        }
        try require(try store.settings(for: a.id) == renamed, "Rejected reassignment modified settings")
        print("PASS endpoint/account reassignment fails closed while names can change")

        let recordA = try store.folder(for: a.id).appendingPathComponent("connection.json")
        for corrupt in [Data("invalid".utf8), Data(repeating: 32, count: 65_537), try JSONEncoder().encode(b)] {
            try corrupt.write(to: recordA)
            let load = try store.load()
            try require(load.connections.contains(b) && load.issues.count == 1, "Bad record hid an independent valid drive")
            try rejects { try store.save(a) }
        }
        try FileManager.default.removeItem(at: recordA)
        try FileManager.default.createSymbolicLink(at: recordA, withDestinationURL: try store.folder(for: b.id).appendingPathComponent("connection.json"))
        try require(try store.load().issues.count == 1, "Symlink record was accepted")
        try rejects { try store.save(a) }
        try FileManager.default.removeItem(at: recordA)
        try store.save(a)
        print("PASS bounded corrupt/mismatched/symlink records are isolated and cannot be overwritten")

        let catalogA = try Catalog(databaseURL: store.folder(for: a.id).appendingPathComponent("catalog.sqlite"))
        let catalogB = try Catalog(databaseURL: store.folder(for: b.id).appendingPathComponent("catalog.sqlite"))
        try await catalogA.setOfflinePolicy(.keepAvailable, for: Catalog.rootID)
        try require(try await catalogB.offlinePolicy(for: Catalog.rootID) == .onDemand, "A pin policy affected B")
        try await catalogB.setOfflinePolicy(.keepAvailable, for: Catalog.rootID)
        try await catalogA.clearOfflineSelections()
        try require(try await catalogB.offlinePolicy(for: Catalog.rootID) == .keepAvailable, "A global offload cleared B policy")
        print("PASS separate real SQLite catalogs isolate pin and global-offload policy")

        let retained = try store.folder(for: a.id).appendingPathComponent("pending-work")
        try Data("retain".utf8).write(to: retained)
        let bBytes = try Data(contentsOf: store.folder(for: b.id).appendingPathComponent("connection.json"))
        try require(try store.removeUnregisteredSettings(a) == store.folder(for: a.id), "Unknown local work was not retained")
        try require(FileManager.default.fileExists(atPath: retained.path), "Pending work was deleted")
        try require(try Data(contentsOf: store.folder(for: b.id).appendingPathComponent("connection.json")) == bBytes, "Removing A changed B")
        try require(try store.removeUnregisteredSettings(settings("unas-test")) == nil, "Empty legacy settings folder was not removed")
        try require(!FileManager.default.fileExists(atPath: store.folder(for: "unas-test").path), "Removed empty folder remains")
        print("PASS confirmed-unregistered cleanup removes only its record and empty directory")
    }
}
