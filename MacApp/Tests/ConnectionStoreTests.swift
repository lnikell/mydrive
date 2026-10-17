import Darwin
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
        try require(mkfifo(recordA.path, 0o600) == 0, "Could not construct malformed FIFO settings fixture")
        try rejects { _ = try store.settings(for: a.id) }
        try require(try store.load().issues.count == 1, "FIFO settings were accepted or hid independent valid drives")
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
        let reloadedRecovery = try store.load().retainedFolders.map { $0.resolvingSymlinksInPath().path }
        try require(reloadedRecovery == [store.folder(for: a.id).resolvingSymlinksInPath().path], "Detached recovery work disappeared after restart")
        try require(try Data(contentsOf: store.folder(for: b.id).appendingPathComponent("connection.json")) == bBytes, "Removing A changed B")
        try require(try store.removeUnregisteredSettings(settings("unas-test")) == nil, "Empty legacy settings folder was not removed")
        try require(!FileManager.default.fileExists(atPath: store.folder(for: "unas-test").path), "Removed empty folder remains")
        print("PASS confirmed-unregistered cleanup removes only its record and empty directory")

        let exported = temporary.appendingPathComponent("OS preserved work", isDirectory: true)
        try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
        try store.retainedWorkLocations.record(exported, domainID: a.id)
        try store.retainedWorkLocations.record(exported, domainID: a.id)
        let afterExportRestart = try ConnectionStore(root: root).load()
        try require(afterExportRestart.retainedFolders.filter { $0 == exported }.count == 1,
                    "An external OS export shortcut disappeared or duplicated after restart")
        let receipts = root.appendingPathComponent("RetainedWork", isDirectory: true)
        let corruptReceipt = receipts.appendingPathComponent(b.id + ".json")
        try FileManager.default.createSymbolicLink(at: corruptReceipt, withDestinationURL: retained)
        try require(try store.load().issues.contains { $0.id == "retained-" + b.id + ".json" },
                    "A malformed recovery receipt was silently accepted")
        try rejects { try store.retainedWorkLocations.record(URL(string: "file://remote.invalid/export")!, domainID: a.id) }
        print("PASS durable OS-export shortcuts survive restart, deduplicate and refuse malformed receipts")

        let detachedID = "ce1b3029-4524-464c-a6de-e34eea86974d"
        let detached = try store.folder(for: detachedID, create: true)
        let unreadable = detached.appendingPathComponent("Mutations", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("unuploaded bytes".utf8).write(to: unreadable.appendingPathComponent("payload"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        let unreadableLoad = try store.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
        try require(unreadableLoad.issues.contains { $0.id == detachedID },
                    "An unreadable staging directory was mistaken for empty")
        try require(try store.load().retainedFolders.contains { $0.lastPathComponent == detachedID },
                    "Readable staged work was not rediscovered")
        print("PASS directory-enumeration errors remain visible and never classify staged work as empty")
    }
}
