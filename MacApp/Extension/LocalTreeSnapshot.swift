import CSQLite
import CryptoKit
import Darwin
import Foundation
import MyDriveCore

/// A frozen local input index, not an upload queue. File Provider's callback
/// owns execution; this module only retains bounded, byte-verified input.
struct LocalTreeSnapshot: Sendable {
    let directory: URL
    let reference: StagedTreeReference

    static func capture(_ source: URL, in staging: MutationStaging,
                        afterFileCopied: @Sendable (String) throws -> Void = { _ in }) async throws -> LocalTreeSnapshot {
        try Task.checkCancellation()
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let sourceFD = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else { throw failure() }
        defer { close(sourceFD) }
        let id = UUID(), directory = location(id, in: staging)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let database = try LocalTreeIndex(directory: directory, create: true)
            try database.insert(path: "", kind: .directory, source: metadata(sourceFD), payload: nil)
            while let pending = try database.nextDirectory() {
                try Task.checkCancellation()
                let fd = try openDirectory(pending.path, beneath: sourceFD, index: database)
                defer { close(fd) }
                try verify(fd, matches: pending.source)
                try rejectResourceFork(fd)
                let streamFD = dup(fd)
                guard streamFD >= 0 else { throw failure() }
                guard let stream = fdopendir(streamFD) else { close(streamFD); throw failure() }
                defer { closedir(stream) }
                errno = 0
                while let entry = readdir(stream) {
                    try Task.checkCancellation()
                    let name = try withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                        try pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                            guard let name = String(validatingCString: $0) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                            return name
                        }
                    }
                    if name == "." || name == ".." { continue }
                    try MutationInput.validateName(name)
                    let path = pending.path.isEmpty ? name : pending.path + "/" + name
                    guard path.utf8.count <= 4096, path.split(separator: "/").count <= 128 else {
                        throw MutationInput.unsupported("This folder is too deeply nested to upload safely. Its local contents are preserved.")
                    }
                    let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else { throw failure() }
                    defer { close(child) }
                    let info = try metadata(child)
                    switch info.mode & S_IFMT {
                    case S_IFDIR:
                        try rejectResourceFork(child)
                        try database.insert(path: path, kind: .directory, source: info, payload: nil)
                    case S_IFREG:
                        guard info.links == 1 else { throw unsupportedShape() }
                        let payload = try copyFile(child, original: info, into: directory)
                        try database.insert(path: path, kind: .file, source: info, payload: payload)
                        try afterFileCopied(path)
                    default: throw unsupportedShape()
                    }
                    errno = 0
                }
                guard errno == 0 else { throw failure() }
                try verify(fd, matches: pending.source)
                try database.seal(pending.path)
                await Task.yield()
            }
            // Detect a formerly copied file changing while later siblings were
            // copied, even when its containing directory's metadata is stable.
            // This is bounded validation, not a claim of a filesystem snapshot
            // transaction across concurrently mutating unrelated files.
            var cursor: String?
            while true {
                let page = try database.sources(after: cursor, limit: 128)
                for node in page {
                    try Task.checkCancellation()
                    let fd: Int32
                    if node.kind == .directory { fd = try openDirectory(node.path, beneath: sourceFD, index: database) }
                    else {
                        let components = node.path.split(separator: "/")
                        let parent = try openDirectory(components.dropLast().joined(separator: "/"), beneath: sourceFD, index: database)
                        defer { close(parent) }
                        fd = openat(parent, String(components.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        guard fd >= 0 else { throw failure() }
                    }
                    defer { close(fd) }
                    try verify(fd, matches: node.source)
                }
                guard let last = page.last else { break }
                cursor = last.path
                await Task.yield()
            }
            var digest = TreeImportDigest(), after: String?
            while true {
                let page = try database.entries(after: after, limit: 128)
                for entry in page { try digest.append(entry) }
                guard let last = page.last else { break }
                after = last.path
            }
            let reference = try digest.reference(id: id)
            try database.finish(reference)
            try syncDirectory(directory)
            try syncDirectory(staging.root)
            return LocalTreeSnapshot(directory: directory, reference: reference)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func load(_ reference: StagedTreeReference, in staging: MutationStaging) throws -> LocalTreeSnapshot {
        let directory = location(reference.id, in: staging)
        let database = try LocalTreeIndex(directory: directory, create: false)
        guard try database.reference() == reference else { throw CocoaError(.fileReadCorruptFile) }
        return LocalTreeSnapshot(directory: directory, reference: reference)
    }

    func entries(after path: String? = nil, limit: Int = 128) throws -> [TreeImportEntry] {
        try LocalTreeIndex(directory: directory, create: false).entries(after: path, limit: limit)
    }

    func sealedDirectories(after path: String? = nil, limit: Int = 128) throws -> [String] {
        try LocalTreeIndex(directory: directory, create: false).directories(after: path, limit: limit, descending: true).map(\.path)
    }

    func payloadURL(_ payload: StagedPayload) -> URL {
        directory.appendingPathComponent(payload.id.uuidString.lowercased() + ".payload")
    }

    func discard() throws { try FileManager.default.removeItem(at: directory); try Self.syncDirectory(directory.deletingLastPathComponent()) }

    /// Only after durable root publication and a recorded local-retirement
    /// checkpoint. A partially removed index is no longer needed to retire it.
    static func retirePublished(_ reference: StagedTreeReference, in staging: MutationStaging) throws {
        let directory = location(reference.id, in: staging)
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw failure() }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.removeItem(at: directory)
        try syncDirectory(staging.root)
    }

    private static func location(_ id: UUID, in staging: MutationStaging) -> URL {
        staging.root.appendingPathComponent(id.uuidString.lowercased() + ".tree", isDirectory: true)
    }

    private static func openDirectory(_ path: String, beneath root: Int32, index: LocalTreeIndex) throws -> Int32 {
        var fd = dup(root)
        guard fd >= 0 else { throw failure() }
        do {
            var prefix = ""
            for part in path.split(separator: "/") {
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard next >= 0 else { throw failure() }
                close(fd); fd = next
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                guard let expected = try index.node(prefix) else { throw CocoaError(.fileReadCorruptFile) }
                try verify(fd, matches: expected.source)
            }
            return fd
        } catch { close(fd); throw error }
    }

    private static func copyFile(_ source: Int32, original: LocalTreeSource, into directory: URL) throws -> StagedPayload {
        try rejectResourceFork(source)
        let id = UUID(), url = directory.appendingPathComponent(id.uuidString.lowercased() + ".payload")
        if fclonefileat(source, AT_FDCWD, url.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            let target = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard target >= 0 else { throw failure() }
            let input = FileHandle(fileDescriptor: source, closeOnDealloc: false)
            let output = FileHandle(fileDescriptor: target, closeOnDealloc: true)
            defer { try? output.close() }
            var copied: Int64 = 0
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                let (next, overflow) = copied.addingReportingOverflow(Int64(bytes.count))
                guard !overflow, next <= original.size else { throw CocoaError(.fileReadCorruptFile) }
                copied = next; try output.write(contentsOf: bytes)
            }
            try output.synchronize()
        }
        let target = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard target >= 0 else { throw failure() }
        let output = FileHandle(fileDescriptor: target, closeOnDealloc: true)
        defer { try? output.close() }
        guard fchmod(target, 0o600) == 0 else { throw failure() }
        try rejectResourceFork(target)
        var digest = SHA256(), count: Int64 = 0
        while let bytes = try output.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            let (next, overflow) = count.addingReportingOverflow(Int64(bytes.count))
            guard !overflow, next <= original.size else { throw CocoaError(.fileReadCorruptFile) }
            count = next; digest.update(data: bytes)
        }
        try verify(source, matches: original)
        guard count == original.size else { throw CocoaError(.fileReadCorruptFile) }
        try output.synchronize()
        return StagedPayload(id: id, size: count,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func metadata(_ fd: Int32) throws -> LocalTreeSource {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure() }
        return LocalTreeSource(info)
    }
    private static func verify(_ fd: Int32, matches original: LocalTreeSource) throws {
        guard try metadata(fd) == original else {
            throw MutationInput.unsupported("The local folder changed while its contents were being preserved. Try saving it again.")
        }
    }
    private static func rejectResourceFork(_ fd: Int32) throws {
        let size = fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0)
        if size > 0 { throw unsupportedShape() }
        if size < 0 && errno != ENOATTR { throw failure() }
    }
    private static func unsupportedShape() -> NSError {
        MutationInput.unsupported("This folder contains a symbolic link, hard link, special file or resource fork that MyDrive cannot preserve safely yet. Its local contents are preserved.")
    }
    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw failure() }
    }
}

struct LocalTreeSource: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let links: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; links = value.st_nlink; size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }
}
