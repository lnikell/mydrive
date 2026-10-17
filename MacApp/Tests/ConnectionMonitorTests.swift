import FileProvider
import Foundation

private enum MonitorTestFailure: Error { case failed(String) }

@MainActor private final class ManualWait {
    var requests: [Duration] = []
    private var order: [UUID] = []
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    var pendingCount: Int { pending.count }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                requests.append(duration)
                order.append(id)
                pending[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, result: .failure(CancellationError())) }
        }
    }

    func advance() {
        guard let id = order.first else { return }
        finish(id, result: .success(()))
    }

    private func finish(_ id: UUID, result: Result<Void, Error>) {
        order.removeAll { $0 == id }
        pending.removeValue(forKey: id)?.resume(with: result)
    }
}

@MainActor private final class RefreshProbe {
    var calls = 0
    var active = 0
    var maximumActive = 0
    var states: [ConnectionMonitor.State] = []
    private var pending: CheckedContinuation<Void, Error>?

    func refresh() async throws {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func finish(_ result: Result<Void, Error> = .success(())) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

/// Controlled waits and refreshes exercise scheduling without contacting a
/// provider, using wall-clock delays, or changing macOS permissions.
@main struct ConnectionMonitorTests {
    @MainActor static func check(_ value: Bool, _ message: String) throws {
        if !value { throw MonitorTestFailure.failed(message) }
    }

    @MainActor static func eventually(_ message: String, _ value: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if value() { return }
            await Task.yield()
        }
        throw MonitorTestFailure.failed(message)
    }

    @MainActor static func main() async throws {
        do {
            let clock = ManualWait()
            let probe = RefreshProbe()
            let monitor = ConnectionMonitor(wait: clock.sleep)
            await monitor.start(refresh: probe.refresh) { probe.states.append($0) }
            try await eventually("Initial wait was not installed") { clock.requests.count == 1 }
            try check(clock.requests == [.seconds(30)] && probe.calls == 0, "Initial refresh skipped its scheduled interval")
            clock.advance()
            try await eventually("Refresh was not started") { probe.calls == 1 }
            for _ in 0..<50 { await Task.yield() }
            try check(clock.requests.count == 1 && probe.maximumActive == 1,
                      "A slow refresh overlapped another refresh or began its next timer early")
            probe.finish()
            try await eventually("Completion did not schedule the next wait") { clock.requests.count == 2 }
            try check(clock.requests == [.seconds(30), .seconds(30)] && probe.states.contains(.refreshed),
                      "Successful refresh did not reset the interval or report completion")
            await monitor.stop()
            try check(clock.pendingCount == 0, "Stop retained a scheduled wait")
        }
        print("PASS refresh intervals begin after completion and never overlap")

        do {
            let clock = ManualWait()
            let probe = RefreshProbe()
            let monitor = ConnectionMonitor(wait: clock.sleep)
            await monitor.start(refresh: probe.refresh) { probe.states.append($0) }
            let transient = NSFileProviderError(.serverUnreachable)
            for (index, delay) in [30, 60, 120, 240, 300, 300].enumerated() {
                try await eventually("Retry wait was not scheduled") { clock.pendingCount == 1 }
                clock.advance()
                try await eventually("Retry refresh was not started") { probe.calls == index + 1 }
                probe.finish(.failure(transient))
                try await eventually("Retry result did not schedule a wait") { clock.requests.count == index + 2 }
                try check(clock.requests.last == .seconds(delay), "Offline backoff escaped its bounded sequence")
            }
            clock.advance()
            try await eventually("Recovery refresh was not started") { probe.calls == 7 }
            probe.finish()
            try await eventually("Recovery did not reset the interval") { clock.requests.count == 8 }
            clock.advance()
            try await eventually("Post-recovery refresh was not started") { probe.calls == 8 }
            probe.finish(.failure(transient))
            try await eventually("Post-recovery failure did not schedule a retry") { clock.requests.count == 9 }
            try check(clock.requests.suffix(2) == [.seconds(30), .seconds(30)],
                      "A successful refresh did not reset offline backoff")
            await monitor.stop()
        }
        print("PASS offline backoff caps at five minutes and resets after success")

        for failure in [
            NSFileProviderError(.notAuthenticated) as NSError,
            CocoaError(.fileReadNoPermission) as NSError,
            URLError(.badURL) as NSError,
            URLError(.userAuthenticationRequired) as NSError,
            NSError(domain: "UnknownProviderFailure", code: 19, userInfo: ["MyDriveControlPhase": "provider_reply"])
        ] {
            let clock = ManualWait()
            let probe = RefreshProbe()
            let monitor = ConnectionMonitor(wait: clock.sleep)
            await monitor.start(refresh: probe.refresh) { probe.states.append($0) }
            try await eventually("Pause test had no initial wait") { clock.pendingCount == 1 }
            clock.advance()
            try await eventually("Pause test refresh did not start") { probe.calls == 1 }
            probe.finish(.failure(failure))
            try await eventually("Permanent failure did not pause") {
                probe.states.last == .paused(message: failure.localizedDescription)
            }
            try check(clock.pendingCount == 0 && clock.requests.count == 1,
                      "Authentication or permanent error was automatically retried")
            await monitor.start(refresh: probe.refresh) { probe.states.append($0) }
            try await eventually("Explicit restart did not resume a paused monitor") { clock.requests.count == 2 }
            await monitor.stop()
        }
        print("PASS authentication and permanent failures pause until explicit restart")

        for failure in [
            URLError(.notConnectedToInternet) as NSError,
            NSError(domain: NSCocoaErrorDomain, code: 4097, userInfo: ["MyDriveControlPhase": "request_transport"]),
            NSError(domain: "MyDriveDiagnostic", code: 124, userInfo: ["MyDriveControlPhase": "deadline"])
        ] {
            let clock = ManualWait()
            let probe = RefreshProbe()
            let monitor = ConnectionMonitor(wait: clock.sleep)
            await monitor.start(refresh: probe.refresh) { probe.states.append($0) }
            try await eventually("Transport test had no wait") { clock.pendingCount == 1 }
            clock.advance()
            try await eventually("Transport test did not refresh") { probe.calls == 1 }
            probe.finish(.failure(failure))
            try await eventually("Transient failure did not schedule a retry") { clock.requests.count == 2 }
            try check(probe.states.last == .retrying(afterSeconds: 30, message: failure.localizedDescription),
                      "A transient failure did not retain its original message and retry interval")
            await monitor.stop()
        }
        print("PASS transient URL, control transport and deadline failures retry")

        do {
            let clock = ManualWait()
            let oldProbe = RefreshProbe()
            let replacement = RefreshProbe()
            let latest = RefreshProbe()
            let monitor = ConnectionMonitor(wait: clock.sleep)
            await monitor.start(refresh: oldProbe.refresh) { oldProbe.states.append($0) }
            try await eventually("Replacement test had no wait") { clock.pendingCount == 1 }
            clock.advance()
            try await eventually("Old refresh did not start") { oldProbe.calls == 1 }
            let first = Task { await monitor.start(refresh: replacement.refresh) { replacement.states.append($0) } }
            await Task.yield()
            let second = Task { await monitor.start(refresh: latest.refresh) { latest.states.append($0) } }
            for _ in 0..<50 { await Task.yield() }
            try check(clock.requests.count == 1 && latest.states.isEmpty && replacement.states.isEmpty,
                      "Replacement bypassed an old request still finishing cancellation")
            oldProbe.finish()
            await first.value
            await second.value
            try await eventually("Latest replacement did not start") { clock.requests.count == 2 }
            try check(replacement.states.isEmpty && latest.states == [.waiting] && oldProbe.states.last == .refreshing,
                      "An older start won the replacement race or emitted a stale completion")
            await monitor.stop()
        }
        print("PASS replacement waits for the previous owner and only the latest start survives")

        do {
            let clock = ManualWait()
            let probe = RefreshProbe()
            let monitor = ConnectionMonitor(wait: clock.sleep)
            await monitor.start(refresh: probe.refresh) { probe.states.append($0) }
            try await eventually("Stop test had no wait") { clock.pendingCount == 1 }
            clock.advance()
            try await eventually("Stop test refresh did not start") { probe.calls == 1 }
            var stopped = false
            let stop = Task { await monitor.stop(); stopped = true }
            for _ in 0..<50 { await Task.yield() }
            try check(!stopped, "Stop returned while its local refresh task was still running")
            probe.finish()
            await stop.value
            try check(stopped && probe.states.last == .refreshing && clock.requests.count == 1,
                      "A cancelled refresh emitted completion or scheduled more work")

            weak var released: ConnectionMonitor?
            do {
                let owned = ConnectionMonitor(wait: clock.sleep)
                released = owned
                await owned.start(refresh: probe.refresh) { probe.states.append($0) }
                try await eventually("Lifetime test had no wait") { clock.pendingCount == 1 }
            }
            try check(released == nil, "The monitor task retained its owner")
            try await eventually("Released owner retained its scheduled wait") { clock.pendingCount == 0 }
        }
        print("PASS stop awaits local cancellation, suppresses late state and releases ownership")
    }
}
