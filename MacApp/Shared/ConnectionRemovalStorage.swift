import Darwin
import Foundation
import MyDriveCore

/// Called only after File Provider confirms removal. Its dirty-data export does
/// not include our staged revisions, journal or remote recovery receipts.
enum ConnectionRemovalStorage {
    static func clean(folder: URL, preserving preserved: URL?, ownerWait: Duration = .seconds(5)) async throws -> URL? {
        var info = stat()
        guard lstat(folder.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadNoPermission) }
        let lease = try await acquireOwner(at: folder.appendingPathComponent("catalog.sqlite.owner"), wait: ownerWait)
        defer { lease.release() }
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if let preserved {
            let retained = preserved.resolvingSymlinksInPath().standardizedFileURL.path
            if retained == path || retained.hasPrefix(path + "/") { return folder }
        }
        // Treat every staging entry, including an unrecognized/unfinished file,
        // as recovery work. Never decode a partial plan to authorize deletion.
        if try hasUnknownEntries(in: folder) || hasStaging(in: folder) { return try retain(folder) }
        if try await hasPendingJournal(in: folder) { return try retain(folder) }
        try FileManager.default.removeItem(at: folder)
        return nil
    }

    private static func acquireOwner(at url: URL, wait: Duration) async throws -> DomainOwnerLease {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while true {
            do { return try DomainOwnerLease(at: url) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileLocking.rawValue {
                guard clock.now < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static func hasStaging(in folder: URL) throws -> Bool {
        let staging = folder.appendingPathComponent("Mutations", isDirectory: true)
        var info = stat()
        guard lstat(staging.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return true }
        return try DirectoryContents.contains(in: staging) { _ in true }
    }

    private static func hasUnknownEntries(in folder: URL) throws -> Bool {
        let known: Set<String> = ["connection.json", "catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm",
                                  "catalog.sqlite.owner", "Mutations", "activity.json", "mount-options.json",
                                  ".bandwidth-upload", ".bandwidth-download"]
        return try DirectoryContents.contains(in: folder) { name in
            guard known.contains(name) else { return true }
            var info = stat()
            guard lstat(folder.appendingPathComponent(name).path, &info) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return info.st_mode & S_IFMT != (name == "Mutations" ? S_IFDIR : S_IFREG)
        }
    }

    private static func retain(_ folder: URL) throws -> URL {
        // Detach only a normal settings record, under the same owner lease.
        // The early preserved-subtree return deliberately never reaches here.
        let record = folder.appendingPathComponent("connection.json")
        var info = stat()
        if lstat(record.path, &info) == 0 {
            if info.st_mode & S_IFMT == S_IFREG { try FileManager.default.removeItem(at: record) }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return folder
    }

    private static func hasPendingJournal(in folder: URL) async throws -> Bool {
        let database = folder.appendingPathComponent("catalog.sqlite")
        var info = stat()
        var sidecars = false
        for suffix in ["-wal", "-shm"] {
            if lstat(database.path + suffix, &info) == 0 {
                sidecars = true
                if info.st_mode & S_IFMT != S_IFREG { return true }
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard lstat(database.path, &info) == 0 else {
            if errno == ENOENT { return sidecars }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return true }
        let catalog = try Catalog(databaseURL: database)
        return try await catalog.hasUnfinishedMutations()
    }
}
