import Foundation
import FileProvider

private enum DomainTestFailure: Error { case failed(String) }

/// Exercise the optimized request owner without opening an XPC connection.
/// In particular, the deadline runs off the main actor. This caught an actor
/// inheritance trap that a successful Swift 6 typecheck did not detect.
@main struct DomainLifetimeTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw DomainTestFailure.failed(message) }
    }

    @MainActor static func main() async throws {
        for _ in 0..<100 {
            let owner = DomainControlOperation<Int>(timeout: 2)
            let value = try await owner.run {
                DispatchQueue.global().async { owner.finish(.success(1)) }
                DispatchQueue.global().async { owner.finish(.success(2)) }
            }
            try check(value == 1 || value == 2, "competing replies returned an unexpected value")
        }
        print("PASS 100 concurrent duplicate-reply races complete once")

        for phase in DomainControlPhase.allCases {
            let owner = DomainControlOperation<Int>(timeout: 2)
            let original = NSFileProviderError(.serverUnreachable) as NSError
            do {
                _ = try await owner.run {
                    owner.finish(.failure(original), phase: phase)
                    owner.finish(.failure(CocoaError(.fileReadNoPermission)), phase: .providerReply)
                }
                throw DomainTestFailure.failed("A phased request error returned success")
            } catch is DomainTestFailure {
                throw DomainTestFailure.failed("A phased request error returned success")
            } catch {
                let failure = error as NSError
                let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
                try check(failure.domain == original.domain && failure.code == original.code,
                          "Phase diagnostics changed OS error classification")
                try check(failure.userInfo["MyDriveControlPhase"] as? String == phase.rawValue,
                          "A late failure replaced the first terminal phase")
                try check(underlying?.domain == original.domain && underlying?.code == original.code &&
                          failure.localizedDescription == original.localizedDescription,
                          "Phase diagnostics changed the user-facing message or lost their original cause")
            }
        }
        print("PASS control failure phases preserve original OS errors and first terminal cause")

        let phasedCancellation = DomainControlOperation<Int>(timeout: 2)
        do {
            _ = try await phasedCancellation.run {
                phasedCancellation.finish(.failure(CancellationError()), phase: .serviceLookup)
            }
            throw DomainTestFailure.failed("Cancellation returned success")
        } catch is CancellationError { }
        let phasedSuccess = DomainControlOperation<Int>(timeout: 2)
        let successValue = try await phasedSuccess.run {
            phasedSuccess.finish(.success(9), phase: .providerReply)
        }
        try check(successValue == 9, "Phase diagnostics changed successful results")
        print("PASS phase diagnostics preserve cancellation and successful values")

        let cancelled = DomainControlOperation<Int>(timeout: 2)
        let task = Task { @MainActor in try await cancelled.run {} }
        task.cancel()
        do {
            _ = try await task.value
            throw DomainTestFailure.failed("pre-bind cancellation returned success")
        } catch is CancellationError { }
        print("PASS cancellation before continuation installation")

        weak var released: DomainControlOperation<Int>?
        do {
            let timed = DomainControlOperation<Int>(timeout: 0.02)
            released = timed
            let started = ContinuousClock.now
            do {
                _ = try await timed.run {}
                throw DomainTestFailure.failed("unanswered request escaped its deadline")
            } catch is DomainTestFailure {
                throw DomainTestFailure.failed("unanswered request returned success")
            } catch {
                try check(started.duration(to: .now) >= .milliseconds(15),
                          "request failed before its configured deadline")
            }
            timed.finish(.success(7)) // A late reply must not resume again.
        }
        try await Task.sleep(for: .milliseconds(20))
        try check(released == nil, "timed-out request retained its owner")
        print("PASS deadline, late reply and owner release")
    }
}
