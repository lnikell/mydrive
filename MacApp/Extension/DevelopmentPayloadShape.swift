#if MYDRIVE_DEVELOPMENT
import Darwin
import Foundation
import OSLog

/// Metadata-only diagnostics for the representation supplied by macOS. Never
/// follows a symlink, traverses a directory or reads/logs a content byte or path.
struct DevelopmentPayloadShape: Sendable {
    let kind: String
    let size: Int64
    let errorCode: Int32
    let contentType: String

    static func inspect(_ url: URL?, contentType: String) -> Self {
        let type = String(contentType.prefix(128))
        guard let url else { return Self(kind: "none", size: -1, errorCode: 0, contentType: type) }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            return Self(kind: "open_failed", size: -1, errorCode: errno, contentType: type)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            return Self(kind: "stat_failed", size: -1, errorCode: errno, contentType: type)
        }
        let kind: String
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = "regular_file"
        case S_IFDIR: kind = "directory"
        case S_IFIFO: kind = "fifo"
        case S_IFLNK: kind = "symlink"
        case S_IFSOCK: kind = "socket"
        default: kind = "other"
        }
        return Self(kind: kind, size: info.st_size, errorCode: 0, contentType: type)
    }

    static func observe(_ url: URL?, contentType: String, operation: String, fields: UInt, options: UInt) {
        guard AppStorage.isDevelopmentStorage else { return }
        let shape = inspect(url, contentType: contentType)
        let operation = operation == "create" ? "create" : "modify"
        let log = Logger(subsystem: "local.mydrive.provider", category: "payload-shape")
        log.notice("\(operation, privacy: .public) contents kind=\(shape.kind, privacy: .public) size=\(shape.size, privacy: .public) errno=\(shape.errorCode, privacy: .public) contentType=\(shape.contentType, privacy: .public) fields=\(fields, privacy: .public) options=\(options, privacy: .public)")
    }
}
#endif
