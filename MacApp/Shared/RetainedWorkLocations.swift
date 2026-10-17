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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileWriteNoPermission) }
        let file = root.appendingPathComponent(domainID + ".json")
        var receipt: Receipt
        do { receipt = try read(file, domainID: domainID) }
        catch let error as POSIXError where error.code == .ENOENT { receipt = Receipt(domainID: domainID, urls: []) }
        if !receipt.urls.contains(url) { receipt.urls.append(url) }
        guard receipt.urls.count <= 128 else { throw CocoaError(.fileWriteOutOfSpace) }
        let bytes = try JSONEncoder().encode(receipt)
        guard bytes.count <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        try bytes.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
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

    private func read(_ url: URL, domainID: String) throws -> Receipt {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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

    private static func valid(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.path.hasPrefix("/") && !url.path.contains("\0") && url.query == nil && url.fragment == nil
    }
}
