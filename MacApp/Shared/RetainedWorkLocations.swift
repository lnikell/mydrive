import Darwin
import Foundation

/// Durable receipts for dirty-data exports returned by macOS during removal.
/// These locate preserved user work; they never authorize deleting that work.
struct RetainedWorkLocations {
    let root: URL
    private let limit = 65_536
    private struct Receipt: Codable {
        let domainID: String
        var urls: [URL]
    }

    func record(_ url: URL, domainID: String) throws {
        guard ConnectionSettings.validDomainID(domainID), Self.valid(url) else { throw CocoaError(.fileWriteInvalidFileName) }
        let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Self.failure() }
        defer { close(parent) }
        let name = root.lastPathComponent
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw Self.failure() }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.failure() }
        defer { close(directory) }
        // The first receipt creates this directory too. Persist that parent
        // entry before returning a durable location for exported user work.
        guard fsync(parent) == 0 else { throw Self.failure() }
        let file = root.appendingPathComponent(domainID + ".json")
        var receipt: Receipt
        do { receipt = try read(file, domainID: domainID, directory: directory) }
        catch let error as POSIXError where error.code == .ENOENT { receipt = Receipt(domainID: domainID, urls: []) }
        if !receipt.urls.contains(url) { receipt.urls.append(url) }
        guard receipt.urls.count <= 128 else { throw CocoaError(.fileWriteOutOfSpace) }
        let bytes = try JSONEncoder().encode(receipt)
        guard bytes.count <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        try write(bytes, name: file.lastPathComponent, directory: directory)
    }

    func load() throws -> (urls: [URL], issues: [ConnectionLoadIssue]) {
        var urls: [URL] = [], issues: [ConnectionLoadIssue] = []
        var count = 0
        do {
            _ = try DirectoryContents.contains(in: root) { name in
                count += 1
                guard count <= 1_024 else { throw CocoaError(.fileReadCorruptFile) }
                let id = String(name.dropLast(5))
                do {
                    guard name.hasSuffix(".json"), ConnectionSettings.validDomainID(id) else { throw CocoaError(.fileReadCorruptFile) }
                    for url in try read(root.appendingPathComponent(name), domainID: id).urls where !urls.contains(url) {
                        urls.append(url)
                    }
                } catch {
                    issues.append(ConnectionLoadIssue(id: "retained-" + name,
                        message: "A retained-work location could not be read: " + String(error.localizedDescription.prefix(512))))
                }
                return false
            }
        } catch let error as POSIXError where error.code == .ENOENT { }
        return (urls, issues)
    }

    private func read(_ url: URL, domainID: String, directory: Int32? = nil) throws -> Receipt {
        let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let descriptor = directory.map { openat($0, url.lastPathComponent, flags) } ?? open(url.path, flags)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = try input.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
        guard receipt.domainID == domainID, receipt.urls.count <= 128, receipt.urls.allSatisfy(Self.valid) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return receipt
    }

    private func write(_ data: Data, name: String, directory: Int32) throws {
        let temporary = "." + UUID().uuidString.lowercased() + ".tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.failure() }
        defer { _ = unlinkat(directory, temporary, 0) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        try output.write(contentsOf: data)
        try output.synchronize()
        try output.close()
        guard renameat(directory, temporary, directory, name) == 0 else { throw Self.failure() }
        guard fsync(directory) == 0 else { throw Self.failure() }
    }

    private static func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func valid(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.path.hasPrefix("/") && !url.path.contains("\0") && url.query == nil && url.fragment == nil
    }
}
