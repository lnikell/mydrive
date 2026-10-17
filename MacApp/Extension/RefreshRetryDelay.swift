import Foundation

/// Connection failures must not turn macOS's repeated enumeration requests into
/// a busy loop. The coordinator waits inside its existing coalesced refresh task.
struct RefreshRetryDelay: Sendable {
    private let interval: Duration
    private var deadline: ContinuousClock.Instant?

    init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    mutating func failed() {
        deadline = ContinuousClock().now.advanced(by: interval)
    }

    mutating func succeeded() {
        deadline = nil
    }

    func wait() async throws {
        try Task.checkCancellation()
        if let deadline {
            try await ContinuousClock().sleep(until: deadline)
        }
    }
}
