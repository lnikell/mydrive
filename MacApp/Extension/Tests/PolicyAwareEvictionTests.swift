import Foundation
import FileProvider
import Darwin

private struct EvictionTestFailure: Error { let message: String }

private actor FakePolicyEviction {
    enum Behavior: Sendable { case transient(Int), alwaysTransient, permanent(NSError) }
    let behavior: Behavior
    let repinAfterFirst: Bool
    private(set) var attempts = 0
    private(set) var policyChecks = 0
    var invalidated = false

    init(_ behavior: Behavior, repinAfterFirst: Bool = false) {
        self.behavior = behavior
        self.repinAfterFirst = repinAfterFirst
    }

    func policy() -> Bool {
        policyChecks += 1
        return repinAfterFirst && attempts > 0
    }

    func active() throws { if invalidated { throw CancellationError() } }
    func invalidate() { invalidated = true }
    func counts() -> (attempts: Int, policyChecks: Int) { (attempts, policyChecks) }

    func attempt() throws {
        attempts += 1
        switch behavior {
        case .transient(let count): if attempts > count { return }
        case .permanent(let error): throw error
        case .alwaysTransient: break
        }
        throw NSFileProviderError(.nonEvictable)
    }

    func run(_ retry: PolicyAwareEviction) async throws -> PolicyAwareEviction.Outcome {
        try await retry.evict(isKeptDownloaded: { await self.policy() },
                             checkActive: { try await self.active() },
                             attempt: { try await self.attempt() })
    }
}

enum PolicyAwareEvictionTests {
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw EvictionTestFailure(message: message) }
    }

    static func run() async throws -> Int {
        let transient = FakePolicyEviction(.transient(2))
        let success = try await transient.run(PolicyAwareEviction(retryWindow: .seconds(1), retryInterval: .milliseconds(2)))
        try check(success == .evicted, "Transient policy transition was not retried")
        let completed = await transient.counts()
        try check(completed.attempts == 3 && completed.policyChecks == 3, "Policy was not checked before every attempt")
        print("PASS transient eviction policy transition and per-attempt policy checks")

        let timed = FakePolicyEviction(.alwaysTransient)
        let window = PolicyAwareEviction(retryWindow: .milliseconds(20), retryInterval: .milliseconds(5))
        let started = ContinuousClock().now
        do {
            _ = try await timed.run(window)
            throw EvictionTestFailure(message: "A persistent nonEvictable failure escaped its deadline")
        } catch let error as NSFileProviderError { try check(error.code == .nonEvictable, "Timeout lost original failure") }
        try check(started.duration(to: .now) < .seconds(1), "Policy retries exceeded their bound")
        let nextFile = FakePolicyEviction(.alwaysTransient)
        do {
            _ = try await nextFile.run(window)
            throw EvictionTestFailure(message: "Expired shared deadline swallowed failure")
        } catch let error as NSFileProviderError {
            try check(error.code == .nonEvictable, "Shared deadline lost failure classification")
        }
        try check(await nextFile.attempts == 1, "Every file started a new retry window")
        print("PASS bounded retry deadline shared across an offload operation")

        let permanent: [NSError] = [
            NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)),
            NSFileProviderError(.unsyncedEdits) as NSError,
            CocoaError(.fileWriteNoPermission) as NSError,
            NSFileProviderError(.nonEvictableChildren) as NSError,
            NSError(domain: "OtherDomain", code: NSFileProviderError.nonEvictable.rawValue)
        ]
        for expected in permanent {
            let state = FakePolicyEviction(.permanent(expected))
            do {
                _ = try await state.run(PolicyAwareEviction())
                throw EvictionTestFailure(message: "Permanent eviction failure was swallowed")
            } catch {
                let actual = error as NSError
                try check(actual.domain == expected.domain && actual.code == expected.code, "Permanent error changed")
            }
            try check(await state.attempts == 1, "A busy, dirty, permission or generic failure was retried")
        }
        print("PASS only exact File Provider nonEvictable errors are retryable")

        let pending = FakePolicyEviction(.alwaysTransient)
        let task = Task { try await pending.run(PolicyAwareEviction(retryWindow: .seconds(10), retryInterval: .seconds(10))) }
        while await pending.attempts == 0 { await Task.yield() }
        let cancelledAt = ContinuousClock().now
        task.cancel()
        do {
            _ = try await task.value
            throw EvictionTestFailure(message: "Cancelled eviction returned success")
        } catch is CancellationError { }
        try check(cancelledAt.duration(to: .now) < .seconds(1), "Cancellation waited for the retry delay")
        try check(await pending.attempts == 1, "Cancellation issued another eviction")
        print("PASS cancellation interrupts policy waiting promptly")

        let invalidated = FakePolicyEviction(.alwaysTransient)
        let invalidation = Task { try await invalidated.run(PolicyAwareEviction(retryWindow: .seconds(1), retryInterval: .milliseconds(5))) }
        while await invalidated.attempts == 0 { await Task.yield() }
        await invalidated.invalidate()
        do {
            _ = try await invalidation.value
            throw EvictionTestFailure(message: "Invalidated owner continued eviction")
        } catch is CancellationError { }
        try check(await invalidated.attempts == 1, "Invalidated owner issued another eviction")
        print("PASS owner invalidation stops further eviction attempts")

        let repinned = FakePolicyEviction(.alwaysTransient, repinAfterFirst: true)
        let retained = try await repinned.run(PolicyAwareEviction(retryWindow: .seconds(1), retryInterval: .milliseconds(2)))
        let kept = await repinned.counts()
        try check(retained == .keptDownloaded && kept.attempts == 1 && kept.policyChecks == 2,
                  "Reapplied pin was ignored")
        print("PASS reapplied offline selection stops policy retries")
        return 6
    }
}
