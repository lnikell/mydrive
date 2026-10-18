import Foundation
import Darwin
import MyDriveCore

private enum RemovalCheckError: Error { case failed(String) }

@main struct ConnectionRemovalStorageTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw RemovalCheckError.failed(message) }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mydrive-removal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Mutations"), withIntermediateDirectories: true)
            return url
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        let clean = try folder("clean")
        _ = try Catalog(databaseURL: clean.appendingPathComponent("catalog.sqlite"))
        for name in ["activity.json", "mount-options.json", ".bandwidth-upload", ".bandwidth-download"] {
            try Data("owned metadata".utf8).write(to: clean.appendingPathComponent(name))
        }
        try check(try await ConnectionRemovalStorage.clean(folder: clean, preserving: nil) == nil && !exists(clean),
                  "Clean removed domain retained its cache")

        let recovery = try folder("recovery")
        let payload = recovery.appendingPathComponent("Mutations/revision.payload")
        let receipt = recovery.appendingPathComponent("Mutations/operation.json")
        let bytes = Data("distinct pending local revision".utf8)
        let evidence = Data("durable remote archive receipt".utf8)
        try bytes.write(to: payload); try evidence.write(to: receipt)
        let detached = recovery.appendingPathComponent("connection.json")
        try Data("{}".utf8).write(to: detached)
        try check(try await ConnectionRemovalStorage.clean(folder: recovery, preserving: nil) == recovery,
                  "Pending recovery data was not retained")
        try check(try Data(contentsOf: payload) == bytes && Data(contentsOf: receipt) == evidence,
                  "Removal changed pending revision or receipt")
        try check(!exists(detached), "Retained recovery data still registered its disconnected settings")

        let journalOnly = try folder("journal-only")
        let catalog = try Catalog(databaseURL: journalOnly.appendingPathComponent("catalog.sqlite"))
        let scan = try await catalog.beginScan()
        try await catalog.stage([RemoteEntry(name: "file", kind: .file, contentVersion: "v", metadataVersion: "m")], in: scan)
        try await catalog.completeScan(scan)
        let item = try await catalog.children().items[0]
        _ = try await catalog.enqueue(JournalIntent(itemID: item.id, expectedVersion: "v", action: .delete))
        try check(try await ConnectionRemovalStorage.clean(folder: journalOnly, preserving: nil) == journalOnly,
                  "Journal without its expected staging directory was discarded")
        let pending = try await catalog.replayableOperations()[0]
        _ = try await catalog.transitionOperation(key: pending.intent.idempotencyKey, from: .queued, to: .executing)
        _ = try await catalog.transitionOperation(key: pending.intent.idempotencyKey, from: .executing, to: .failed)
        try check(try await catalog.replayableOperations().isEmpty, "Failed test operation remained replayable")
        try check(try await ConnectionRemovalStorage.clean(folder: journalOnly, preserving: nil) == journalOnly,
                  "Cleanup discarded a failed operation that can still be retried")

        let osWork = try folder("os-work")
        let preserved = osWork.appendingPathComponent("Recovered work")
        try bytes.write(to: preserved)
        try check(try await ConnectionRemovalStorage.clean(folder: osWork, preserving: preserved) == osWork && exists(preserved),
                  "OS preserved work inside the connection folder was removed")
        let preservedRecord = try folder("preserved-record")
        let exactRecord = preservedRecord.appendingPathComponent("connection.json")
        try bytes.write(to: exactRecord)
        try check(try await ConnectionRemovalStorage.clean(folder: preservedRecord, preserving: exactRecord) == preservedRecord,
                  "OS preserved settings record did not retain its folder")
        try check(try Data(contentsOf: exactRecord) == bytes, "Settings detachment changed an OS preserved file")

        let active = try folder("active")
        let lease = try DomainOwnerLease(at: active.appendingPathComponent("catalog.sqlite.owner"))
        do {
            _ = try await ConnectionRemovalStorage.clean(folder: active, preserving: nil, ownerWait: .zero)
            throw RemovalCheckError.failed("Cleanup bypassed the provider's live owner lease")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileLocking.rawValue { }
        try check(exists(active), "Owner exclusion removed active data")
        let release = Task { try await Task.sleep(for: .milliseconds(50)); lease.release() }
        try check(try await ConnectionRemovalStorage.clean(folder: active, preserving: nil, ownerWait: .seconds(1)) == nil,
                  "Cleanup failed to wait for drained provider callbacks")
        try await release.value

        let unknown = try folder("unknown")
        let foreign = unknown.appendingPathComponent("unrecognized-local-work")
        try bytes.write(to: foreign)
        try check(try await ConnectionRemovalStorage.clean(folder: unknown, preserving: nil) == unknown && exists(foreign),
                  "Cleanup discarded an unrecognized local file")

        let links = try folder("links")
        let linkStaging = links.appendingPathComponent("Mutations")
        try FileManager.default.removeItem(at: linkStaging)
        try FileManager.default.createSymbolicLink(at: linkStaging, withDestinationURL: recovery.appendingPathComponent("Mutations"))
        try check(try await ConnectionRemovalStorage.clean(folder: links, preserving: nil) == links && exists(payload),
                  "Cleanup followed a staging symlink")

        let corrupt = try folder("corrupt")
        let corruptDB = corrupt.appendingPathComponent("catalog.sqlite")
        try bytes.write(to: corruptDB)
        do {
            _ = try await ConnectionRemovalStorage.clean(folder: corrupt, preserving: nil)
            throw RemovalCheckError.failed("Corrupt recovery state authorized cleanup")
        } catch is CatalogError { }
        try check(try Data(contentsOf: corruptDB) == bytes, "Cleanup modified a corrupt recovery record")

        for sidecar in ["catalog.sqlite-wal", "catalog.sqlite-shm"] {
            let orphaned = try folder("orphaned-" + sidecar)
            let record = orphaned.appendingPathComponent(sidecar)
            try bytes.write(to: record)
            try check(try await ConnectionRemovalStorage.clean(folder: orphaned, preserving: nil) == orphaned,
                      "Orphaned SQLite sidecar authorized cleanup")
            try check(try Data(contentsOf: record) == bytes, "Orphaned journal bytes changed")
        }
        for name in ["connection.json", "catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm"] {
            let malformed = try folder("directory-" + name)
            let directory = malformed.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let work = directory.appendingPathComponent("Recovered.txt")
            try bytes.write(to: work)
            try check(try await ConnectionRemovalStorage.clean(folder: malformed, preserving: nil) == malformed && exists(work),
                      "A known filename with unexpected directory shape discarded local work")
        }
        let fifo = try folder("fifo-owner")
        let fifoOwner = fifo.appendingPathComponent("catalog.sqlite.owner")
        guard mkfifo(fifoOwner.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        do {
            _ = try await ConnectionRemovalStorage.clean(folder: fifo, preserving: nil, ownerWait: .zero)
            throw RemovalCheckError.failed("FIFO accepted as a domain owner lease")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue { }
        try check(exists(fifo), "Malformed owner lease authorized cleanup")
        print("Connection-removal storage checks passed")
    }
}
