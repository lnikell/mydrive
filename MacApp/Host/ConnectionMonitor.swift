import FileProvider
import Foundation

/// Schedules requests to the provider owner. It neither accesses the NAS nor
/// interprets the catalog. Intervals begin after a request completes, and an
/// explicit start is the only way to resume a paused monitor.
@MainActor final class ConnectionMonitor {
    enum State: Equatable, Sendable {
        case waiting
        case refreshing
        case refreshed
        case retrying(afterSeconds: Int, message: String)
        case paused(message: String)
    }

    typealias Refresh = @MainActor @Sendable () async throws -> Void
    typealias StateSink = @MainActor @Sendable (State) -> Void
    typealias Wait = @MainActor @Sendable (Duration) async throws -> Void

    private let wait: Wait
    private var task: Task<Void, Never>?
    private var revision: UInt64 = 0

    init(wait: @escaping Wait = { try await Task.sleep(for: $0) }) {
        self.wait = wait
    }

    deinit { task?.cancel() }

    func start(interval: Int = 30, refresh: @escaping Refresh, onState: @escaping StateSink) async {
        revision &+= 1
        let requestedRevision = revision
        let previous = task
        previous?.cancel()
        // Keep the previous task installed while awaiting it so overlapping
        // start/stop calls cannot bypass an owner still finishing cancellation.
        await previous?.value
        guard revision == requestedRevision, !Task.isCancelled else { return }
        let wait = self.wait
        task = Task { await Self.run(baseInterval: max(1, interval), refresh: refresh, onState: onState, wait: wait) }
    }

    /// Ends local waiting before removal. It cannot undo provider work that an
    /// already-dispatched request may have accepted.
    func stop() async {
        revision &+= 1
        let requestedRevision = revision
        let previous = task
        previous?.cancel()
        await previous?.value
        if revision == requestedRevision { task = nil }
    }

    private static func run(baseInterval: Int, refresh: Refresh, onState: StateSink, wait: Wait) async {
        guard !Task.isCancelled else { return }
        var interval = baseInterval
        var retryInterval = baseInterval
        onState(.waiting)
        while !Task.isCancelled {
            do {
                try await wait(.seconds(interval))
                try Task.checkCancellation()
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                onState(.paused(message: error.localizedDescription))
                return
            }
            onState(.refreshing)
            do {
                try await refresh()
                try Task.checkCancellation()
                interval = baseInterval
                retryInterval = baseInterval
                onState(.refreshed)
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                guard shouldRetry(error) else {
                    onState(.paused(message: error.localizedDescription))
                    return
                }
                interval = retryInterval
                retryInterval = min(retryInterval * 2, 300)
                onState(.retrying(afterSeconds: interval, message: error.localizedDescription))
            }
        }
    }

    private static func shouldRetry(_ error: any Error) -> Bool {
        let failure = error as NSError
        if failure.domain == NSFileProviderErrorDomain {
            return failure.code == NSFileProviderError.serverUnreachable.rawValue
        }
        if failure.domain == NSURLErrorDomain {
            // Invalid URLs, credential challenges, TLS failures and explicit
            // cancellation need attention rather than repeated network work.
            return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost,
                    .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet]
                .contains { failure.code == $0.rawValue }
        }
        // DomainControlOperation sets these only for the request transport or
        // its deadline. A provider reply with an unknown error stays paused.
        return ["request_transport", "deadline"].contains(
            failure.userInfo["MyDriveControlPhase"] as? String ?? "")
    }
}
