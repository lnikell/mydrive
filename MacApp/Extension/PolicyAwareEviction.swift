import Foundation
import FileProvider

/// macOS may briefly retain the old eager policy after its replacement is
/// published. One operation shares this retry window across all selected files.
/// The window bounds retries between completed OS requests, not an in-flight
/// request owned by File Provider.
struct PolicyAwareEviction: Sendable {
    enum Outcome: Equatable, Sendable { case evicted, keptDownloaded }

    private let deadline: ContinuousClock.Instant
    private let retryInterval: Duration

    init(retryWindow: Duration = .seconds(5), retryInterval: Duration = .milliseconds(200)) {
        precondition(retryWindow >= .zero && retryInterval > .zero)
        deadline = ContinuousClock().now.advanced(by: retryWindow)
        self.retryInterval = retryInterval
    }

    func evict(
        isKeptDownloaded: @Sendable () async throws -> Bool,
        checkActive: @Sendable () async throws -> Void,
        attempt: @Sendable () async throws -> Void
    ) async throws -> Outcome {
        let clock = ContinuousClock()
        var previousFailure: (any Error)?
        while true {
            try Task.checkCancellation()
            try await checkActive()
            if try await isKeptDownloaded() { return .keptDownloaded }
            try Task.checkCancellation()
            try await checkActive()
            if let previousFailure, clock.now >= deadline { throw previousFailure }
            do {
                try await attempt()
                return .evicted
            } catch {
                try Task.checkCancellation()
                try await checkActive()
                let failure = error as NSError
                guard failure.domain == NSFileProviderErrorDomain,
                      failure.code == NSFileProviderError.nonEvictable.rawValue,
                      clock.now < deadline else { throw error }
                previousFailure = error
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: retryInterval)))
            }
        }
    }
}
