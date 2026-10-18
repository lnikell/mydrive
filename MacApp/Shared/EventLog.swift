import Darwin
import Foundation

/// Bounded diagnostics contain event names, counts and error codes, never
/// credentials, transport request bodies, or file contents.
enum EventLog {
    private static let retention = LogRetention()
    static func directory() throws -> URL {
        let url = try AppStorage.rootURL().appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if retention.shouldClean() {
            let prefix = (Bundle.main.bundleIdentifier ?? "mydrive") + "-"
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jsonl" }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                    ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for file in files.dropFirst(4) {
                var info = stat()
                if lstat(file.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG { try? FileManager.default.removeItem(at: file) }
            }
        }
        return url
    }

    static func record(_ event: String, error: (any Error)? = nil, verbose: Bool = false) {
        if verbose, (try? PreferencesStore.shared().load().verboseLogging) != true { return }
        do {
            let folder = try directory()
            let file = folder.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "mydrive")-\(getpid()).jsonl")
            var info = stat()
            if lstat(file.path, &info) == 0, info.st_size > 1_048_576 { return }
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var entry: [String: Any] = ["date": Date().ISO8601Format(), "event": String(event.prefix(128))]
            if let error = error as NSError? { entry["errorDomain"] = error.domain; entry["errorCode"] = error.code }
            var bytes = try JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)
            bytes.append(10)
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        } catch { /* Logging cannot change a committed file operation's result. */ }
    }
}

private final class LogRetention: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCleaned = Date.distantPast
    func shouldClean() -> Bool {
        lock.withLock {
            guard Date().timeIntervalSince(lastCleaned) >= 600 else { return false }
            lastCleaned = Date(); return true
        }
    }
}
