import Foundation

/// Bounds the local wait for an uncancellable File Provider request. A timeout
/// or cancellation does not undo an eviction already accepted by macOS.
final class RemovalEvictionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    static func run(
        until deadline: ContinuousClock.Instant,
        isolation: isolated (any Actor)? = #isolation,
        start: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw RemovalEviction.Failure.deadline }
        let request = RemovalEvictionRequest()
        let timer = Task { @Sendable in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                request.finish(.failure(RemovalEviction.Failure.deadline))
            } catch { }
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if request.install(continuation) {
                    start { @Sendable error in
                        request.finish(error.map { .failure($0) } ?? .success(()))
                    }
                }
            }
        } onCancel: { request.finish(.failure(CancellationError())) }
    }

    private func install(_ value: CheckedContinuation<Void, any Error>) -> Bool {
        lock.lock()
        if let outcome { lock.unlock(); value.resume(with: outcome); return false }
        continuation = value
        lock.unlock()
        return true
    }

    private func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}
