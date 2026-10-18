import Foundation

struct DirectoryRefresh: Sendable {
    let id: UUID
    let completion: Task<Void, Error>
    let visibility: FirstDirectoryVisibility
}

/// A refresh has one first-publication/terminal result and bounded waiters.
/// The existing refresh task owns I/O; cancelling a waiter never detaches it.
actor FirstDirectoryVisibility {
    private var outcome: Result<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var waitingCount: Int { waiters.count }

    func wait() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if let outcome { continuation.resume(with: outcome) }
                else if waiters.count >= 128 { continuation.resume(throwing: CocoaError(.fileLocking)) }
                else { waiters[id] = continuation }
            }
        } onCancel: { Task { await self.cancel(id) } }
        try Task.checkCancellation()
    }

    func resolve(_ value: Result<Void, Error>) {
        guard outcome == nil else { return }
        outcome = value
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending { continuation.resume(with: value) }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
