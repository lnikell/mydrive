import Foundation
import Darwin

/// A process-local actor does not exclude a replacement extension process.
/// The kernel releases this advisory lock if its owner crashes.
final class DomainOwnerLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(at url: URL) throws {
        let opened = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard opened >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: Self.posixError()])
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let underlying = Self.posixError()
            Darwin.close(opened)
            throw CocoaError(.fileLocking, userInfo: [
                NSLocalizedDescriptionKey: "Another MyDrive extension instance still owns this connection.",
                NSUnderlyingErrorKey: underlying])
        }
        descriptor = opened
    }

    func release() {
        lock.lock()
        let opened = descriptor
        descriptor = -1
        lock.unlock()
        if opened >= 0 {
            flock(opened, LOCK_UN)
            Darwin.close(opened)
        }
    }

    deinit { release() }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
