import Darwin
import Foundation

struct ConnectionLoadIssue: Identifiable, Sendable {
    let id: String
    let message: String
}

struct SavedConnections: Sendable {
    let connections: [ConnectionSettings]
    let issues: [ConnectionLoadIssue]
    var retainedFolders: [URL] = []
}

enum ConnectionStoreError: LocalizedError {
    case endpointChanged, invalidSettings
    var errorDescription: String? {
        switch self {
        case .endpointChanged: "Remove this drive before changing its server, shared drive, or account."
        case .invalidSettings: "Enter a drive name, server, shared drive, and username."
        }
    }
}

/// The existing per-domain records are the source of truth. There is no second
/// manifest to reconcile after a crash. All reads are bounded and create nothing.
struct ConnectionStore: Sendable {
    let root: URL
    private static let maximumRecordBytes = 65_536

    func folder(for id: String, create: Bool = false) throws -> URL {
        guard ConnectionSettings.validDomainID(id) else { throw CocoaError(.fileReadInvalidFileName) }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        var info = stat()
        if lstat(folder.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadNoPermission) }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if create { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return folder
    }

    func settings(for id: String) throws -> ConnectionSettings {
        let url = try folder(for: id).appendingPathComponent("connection.json")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= Self.maximumRecordBytes else { throw CocoaError(.fileReadCorruptFile) }
        var bytes = Data()
        while let chunk = try input.read(upToCount: Self.maximumRecordBytes + 1 - bytes.count), !chunk.isEmpty {
            bytes.append(chunk)
            if bytes.count > Self.maximumRecordBytes { break }
        }
        guard bytes.count <= Self.maximumRecordBytes else { throw CocoaError(.fileReadCorruptFile) }
        let settings = try JSONDecoder().decode(ConnectionSettings.self, from: bytes)
        guard settings.domainID == id else { throw CocoaError(.fileReadCorruptFile) }
        try Self.validate(settings)
        return settings
    }

    func existingSettings(for id: String) throws -> ConnectionSettings? {
        do { return try settings(for: id) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue].contains(error.code) {
            return nil
        }
    }

    func load() throws -> SavedConnections {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return SavedConnections(connections: [], issues: [])
        }
        var connections: [ConnectionSettings] = []
        var issues: [ConnectionLoadIssue] = []
        var retained: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            let id = url.lastPathComponent
            guard ConnectionSettings.validDomainID(id) else { continue }
            do {
                guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                if let settings = try existingSettings(for: id) { connections.append(settings) }
                else if try containsDetachedData(in: url) { retained.append(url) }
            } catch {
                issues.append(ConnectionLoadIssue(id: id, message: "Saved drive \(id): " + String(error.localizedDescription.prefix(512))))
            }
        }
        connections.sort { $0.domainID < $1.domainID }
        do {
            let exported = try retainedWorkLocations.load()
            for url in exported.urls where !retained.contains(url) { retained.append(url) }
            issues.append(contentsOf: exported.issues)
        } catch {
            issues.append(ConnectionLoadIssue(id: "retained-work", message:
                "Retained-work locations could not be read: " + String(error.localizedDescription.prefix(512))))
        }
        return SavedConnections(connections: connections, issues: issues, retainedFolders: retained.sorted { $0.path < $1.path })
    }

    var retainedWorkLocations: RetainedWorkLocations {
        RetainedWorkLocations(root: root.appendingPathComponent("RetainedWork", isDirectory: true))
    }

    /// Only inspect names, never payloads or plans. A missing connection record
    /// must not make retained upload recovery work disappear after app restart.
    private func containsDetachedData(in folder: URL) throws -> Bool {
        try DirectoryContents.contains(in: folder) { name in
            if name == "catalog.sqlite.owner" { return false }
            let entry = folder.appendingPathComponent(name)
            var info = stat()
            guard lstat(entry.path, &info) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if name == "mount-options.json", info.st_mode & S_IFMT == S_IFREG { return false }
            if name == "Mutations", info.st_mode & S_IFMT == S_IFDIR {
                return try DirectoryContents.contains(in: entry) { _ in true }
            }
            return true
        }
    }

    func save(_ settings: ConnectionSettings) throws {
        try Self.validate(settings)
        if let previous = try existingSettings(for: settings.domainID), !settings.hasSameEndpoint(as: previous) {
            throw ConnectionStoreError.endpointChanged
        }
        let bytes = try JSONEncoder().encode(settings)
        guard bytes.count <= Self.maximumRecordBytes else { throw ConnectionStoreError.invalidSettings }
        try bytes.write(to: folder(for: settings.domainID, create: true).appendingPathComponent("connection.json"), options: .atomic)
    }

    /// Only after the system confirms that no domain is registered. Remove the
    /// configuration and an empty folder; never recursively delete retained work.
    func removeUnregisteredSettings(_ settings: ConnectionSettings) throws -> URL? {
        if let previous = try existingSettings(for: settings.domainID), !settings.hasSameEndpoint(as: previous) {
            throw ConnectionStoreError.endpointChanged
        }
        let directory = try folder(for: settings.domainID)
        let record = directory.appendingPathComponent("connection.json")
        do { try FileManager.default.removeItem(at: record) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code) { }
        var hasOtherData = true
        do {
            hasOtherData = try DirectoryContents.contains(in: directory) { name in
                guard name == "mount-options.json" else { return true }
                var info = stat()
                guard lstat(directory.appendingPathComponent(name).path, &info) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return info.st_mode & S_IFMT != S_IFREG
            }
        } catch let error as POSIXError where error.code == .ENOENT {
            // A disappeared entry is not proof that the whole folder is empty.
            // rmdir below decides, without traversing or deleting any contents.
        }
        if !hasOtherData {
            let options = directory.appendingPathComponent("mount-options.json")
            if unlink(options.path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        if rmdir(directory.path) == 0 || errno == ENOENT { return nil }
        if errno == ENOTEMPTY { return directory }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func validate(_ settings: ConnectionSettings) throws {
        guard ConnectionSettings.validDomainID(settings.domainID),
              !settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.host.isEmpty, !settings.share.isEmpty, !settings.username.isEmpty,
              [settings.displayName, settings.host, settings.share, settings.username].allSatisfy({ !$0.contains("\0") }) else {
            throw ConnectionStoreError.invalidSettings
        }
    }
}
