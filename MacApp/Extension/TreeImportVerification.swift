import CryptoKit
import Darwin
import Foundation

enum TreeImportVerification {
    static func hash(_ url: URL, expectedBytes: Int64) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == expectedBytes else { throw SMBClientError.invalidResponse }
        var digest = SHA256(), count: Int64 = 0
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            let (next, overflow) = count.addingReportingOverflow(Int64(data.count))
            guard !overflow, next <= expectedBytes else { throw SMBClientError.invalidResponse }
            count = next; digest.update(data: data)
        }
        guard count == expectedBytes else { throw SMBClientError.invalidResponse }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
