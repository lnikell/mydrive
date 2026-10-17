import CryptoKit
import Darwin
import Foundation
import MyDriveCore

extension LocalTreeSnapshot {
    /// Before discarding an independent equivalent capture, attest every
    /// retained byte as well as the bounded index. Uploads still verify their
    /// own payloads; this check only authorizes local copy retirement.
    func validateContents() async throws {
        var digest = TreeImportDigest(), cursor: String?
        while true {
            let page = try entries(after: cursor, limit: 128)
            for entry in page {
                try Task.checkCancellation()
                try digest.append(entry)
                if let payload = entry.payload { try validate(payload) }
            }
            guard let last = page.last else { break }
            cursor = last.path
            await Task.yield()
        }
        guard try digest.reference(id: reference.id) == reference else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func validate(_ payload: StagedPayload) throws {
        let fd = open(payloadURL(payload).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size == payload.size else { throw CocoaError(.fileReadCorruptFile) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256(), count: Int64 = 0
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            let (next, overflow) = count.addingReportingOverflow(Int64(bytes.count))
            guard !overflow, next <= payload.size else { throw CocoaError(.fileReadCorruptFile) }
            count = next; hash.update(data: bytes)
        }
        var after = stat()
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard fstat(fd, &after) == 0, LocalTreeSource(before) == LocalTreeSource(after),
              count == payload.size, actual == payload.sha256 else { throw CocoaError(.fileReadCorruptFile) }
    }
}
