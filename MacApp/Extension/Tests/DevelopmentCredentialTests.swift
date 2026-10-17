#if MYDRIVE_DEVELOPMENT
import Foundation
import FileProvider

private struct SessionTestFailure: Error { let message: String }
private func ensure(_ condition: Bool, _ message: String) throws {
    if !condition { throw SessionTestFailure(message: message) }
}
private func expectFailure(_ operation: () async throws -> Void) async throws {
    do { try await operation() }
    catch { return }
    throw SessionTestFailure(message: "A disallowed development credential operation succeeded")
}

private final class TestCredentialStore: DevelopmentCredentialPersistence, @unchecked Sendable {
    enum Failure { case none, load, saveAfterWrite, mismatchedReadback, remove, saveAndCleanup }
    private let lock = NSLock()
    private var data: Data?
    private var failure = Failure.none
    private var events: [String] = []
    private var onSave: (@Sendable () -> Void)?

    func configure(_ failure: Failure = .none, onSave: (@Sendable () -> Void)? = nil) {
        lock.withLock { self.failure = failure; self.onSave = onSave }
    }
    func replace(_ data: Data?) { lock.withLock { self.data = data } }
    func snapshot() -> (Data?, [String]) { lock.withLock { (data, events) } }
    func recordVerification() { lock.withLock { events.append("verify") } }
    func load(for settings: ConnectionSettings) throws -> Data? {
        try lock.withLock {
            events.append("load")
            if failure == .load { throw SessionTestFailure(message: "Unavailable test store") }
            if failure == .mismatchedReadback, let data { return data + Data("\n".utf8) }
            return data
        }
    }
    func save(_ data: Data, for settings: ConnectionSettings) throws {
        let hook: (@Sendable () -> Void)? = try lock.withLock {
            events.append("save")
            self.data = data
            if failure == .saveAfterWrite || failure == .saveAndCleanup {
                throw SessionTestFailure(message: "Uncertain test store save")
            }
            return onSave
        }
        hook?()
    }
    func remove(for settings: ConnectionSettings) throws {
        try lock.withLock {
            events.append("remove")
            if failure == .remove || (failure == .saveAndCleanup && data != nil) {
                throw SessionTestFailure(message: "Test store deletion failed")
            }
            data = nil
        }
    }
}

private final class TestSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private final class KeyedCredentialStore: DevelopmentCredentialPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    func load(for settings: ConnectionSettings) throws -> Data? { lock.withLock { records[settings.id] } }
    func save(_ data: Data, for settings: ConnectionSettings) throws { lock.withLock { records[settings.id] = data } }
    func remove(for settings: ConnectionSettings) throws { _ = lock.withLock { records.removeValue(forKey: settings.id) } }
}

private actor VerificationLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    var started = false
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor VerificationCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// All clients below are constructed only; none performs SMB or Keychain I/O.
/// Restart tests share opaque fake storage across independent session actors.
enum DevelopmentCredentialTests {
    private static let buildID = "D715FD19-133D-40A2-B822-27442F017FF6"
    private static let settings = ConnectionSettings(
        domainID: "unas-test", displayName: "Test NAS", host: "192.0.2.1:445",
        share: "mydrive-test", username: "mydrive-test")

    private static func session(
        _ store: TestCredentialStore, clock: TestSessionClock = TestSessionClock(),
        lifetime: Duration = .seconds(900), buildID: String? = buildID
    ) -> DevelopmentCredentialSession {
        DevelopmentCredentialSession(store: store, lifetime: lifetime,
            buildIdentifier: { buildID }, now: { clock.now() })
    }

    static func run() async throws -> Int {
        let example = try DevelopmentConnectionScope.settings(domainID: "unas-test", info: [:])
        try ensure(example == settings, "Standalone tests did not use the public example target")
        let metadata: [String: String] = ["host": "192.0.2.2:445", "share": "custom-test", "username": "custom-test"]
        let info: [String: Any] = ["MyDriveDevelopmentBuild": true, "MyDriveDevelopmentConnection": metadata]
        let configured = try DevelopmentConnectionScope.settings(domainID: "unas-test", info: info)
        try DevelopmentConnectionScope.validate(configured, info: info)
        let unicodeInfo: [String: Any] = ["MyDriveDevelopmentConnection": metadata.merging(["share": "caf\u{e9}"]) { _, new in new }]
        var normalized = try DevelopmentConnectionScope.settings(domainID: "unas-test", info: unicodeInfo)
        normalized.share = "cafe\u{301}"
        do {
            try DevelopmentConnectionScope.validate(normalized, info: unicodeInfo)
            throw SessionTestFailure(message: "Canonical String equality broadened the exact target bytes")
        } catch let error as CocoaError where error.code == .fileReadNoPermission { }
        for invalid: [String: Any] in [
            ["MyDriveDevelopmentBuild": true],
            ["MyDriveDevelopmentConnection": "invalid"],
            ["MyDriveDevelopmentConnection": metadata.merging(["password": "dummy"]) { _, new in new }],
            ["MyDriveDevelopmentConnection": metadata.merging(["host": ""]) { _, new in new }],
            ["MyDriveDevelopmentConnection": metadata.merging(["share": "test\nshare"]) { _, new in new }],
            ["MyDriveDevelopmentConnection": metadata.merging(["username": String(repeating: "é", count: 513)]) { _, new in new }]
        ] {
            do {
                _ = try DevelopmentConnectionScope.settings(domainID: "unas-test", info: invalid)
                throw SessionTestFailure(message: "Malformed development target was accepted")
            } catch let error as CocoaError where error.code == .fileReadNoPermission { }
        }
        do {
            try DevelopmentConnectionScope.validate(example, info: info)
            throw SessionTestFailure(message: "Public fallback broadened a configured development target")
        } catch let error as CocoaError where error.code == .fileReadNoPermission { }
        print("PASS bundle development metadata is exact, bounded and fails closed without expanding scope")

        let store = TestCredentialStore()
        let denied = session(store)
        let attempts = VerificationCount()
        let verify: @Sendable (String) async throws -> Void = { _ in await attempts.increment() }
        try await expectFailure {
            try await denied.install("dummy", settings: settings, isDevelopmentBuild: false, verify: verify)
        }
        let wrongDomain = ConnectionSettings(domainID: "another-domain", displayName: settings.displayName,
            host: settings.host, share: settings.share, username: settings.username)
        var wrongHost = settings; wrongHost.host = "192.0.2.1"
        var wrongShare = settings; wrongShare.share = "another-share"
        var wrongUser = settings; wrongUser.username = "another-user"
        for connection in [wrongDomain, wrongHost, wrongShare, wrongUser] {
            try await expectFailure {
                try await denied.install("dummy", settings: connection, isDevelopmentBuild: true, verify: verify)
            }
        }
        for invalid in ["", String(repeating: "é", count: 2049)] {
            try await expectFailure {
                try await denied.install(invalid, settings: settings, isDevelopmentBuild: true, verify: verify)
            }
        }
        for invalidBuild: String? in [nil, "not-a-uuid"] {
            let invalid = session(store, buildID: invalidBuild)
            try await expectFailure {
                try await invalid.install("dummy", settings: settings, isDevelopmentBuild: true, verify: verify)
            }
        }
        try ensure(await attempts.value == 0 && store.snapshot().1.isEmpty,
                   "Rejected scope or input touched verification/persistence")
        try await denied.install(String(repeating: "x", count: 4096), settings: settings,
                                 isDevelopmentBuild: true, verify: verify)
        try ensure(await attempts.value == 1, "Boundary credential was not verified")
        await denied.invalidate()
        print("PASS development, exact scope/build, and UTF-8 gates precede persistence")

        let durableStore = TestCredentialStore(), clock = TestSessionClock()
        let first = session(durableStore, clock: clock)
        try await first.install("dummy-durable", settings: settings, isDevelopmentBuild: true) { _ in
            durableStore.recordVerification()
        }
        let original = durableStore.snapshot().0
        try ensure(durableStore.snapshot().1 == ["remove", "verify", "save", "load"],
                   "Persistence preceded verification or omitted byte-exact readback")
        await first.invalidate()
        try ensure(durableStore.snapshot().0 == original, "Invalidation deleted the restart record")
        clock.advance(600)
        let restarted = session(durableStore, clock: clock)
        _ = try await restarted.client(settings: settings, isDevelopmentBuild: true)
        try ensure(durableStore.snapshot().0 == original, "Restart rewrote/extended expiry")
        clock.advance(301)
        try await expectAuthenticationFailure(restarted)
        try ensure(durableStore.snapshot().0 == nil, "Expired durable record was not removed")
        await restarted.invalidate()
        print("PASS provider restart reads its record without extending absolute expiry")

        let replacementStore = TestCredentialStore()
        let replacement = session(replacementStore, lifetime: .milliseconds(200))
        try await replacement.install("dummy-first", settings: settings, isDevelopmentBuild: true) { _ in }
        try await Task.sleep(for: .milliseconds(120))
        try await replacement.install("dummy-second", settings: settings, isDevelopmentBuild: true) { _ in }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await replacement.client(settings: settings, isDevelopmentBuild: true)
        try await replacement.forget(settings: settings, isDevelopmentBuild: true)
        try await expectAuthenticationFailure(session(replacementStore))
        await replacement.invalidate()
        print("PASS replacement cancels old expiry and explicit forget survives restart")

        let lateStore = TestCredentialStore()
        // Separate store makes any accidental superseded write observable.
        let latest = session(lateStore), latch = VerificationLatch()
        let slow = Task {
            try await latest.install("dummy-slow", settings: settings, isDevelopmentBuild: true) { _ in
                await latch.wait() // Intentionally ignores cancellation until released.
            }
        }
        while !(await latch.started) { await Task.yield() }
        try await latest.install("dummy-current", settings: settings, isDevelopmentBuild: true) { _ in }
        let acknowledged = lateStore.snapshot().0
        await latch.release()
        do { try await slow.value; throw SessionTestFailure(message: "Superseded verification committed") }
        catch is CancellationError {}
        try ensure(lateStore.snapshot().0 == acknowledged, "Superseded probe changed acknowledged record")
        _ = try await latest.client(settings: settings, isDevelopmentBuild: true)
        await latest.invalidate()
        print("PASS superseded verification cannot overwrite or delete the current record")

        for failure in [TestCredentialStore.Failure.saveAfterWrite, .mismatchedReadback] {
            let brokenStore = TestCredentialStore(); brokenStore.configure(failure)
            let broken = session(brokenStore)
            try await expectFailure {
                try await broken.install("dummy-unacknowledged", settings: settings, isDevelopmentBuild: true) { _ in }
            }
            try ensure(brokenStore.snapshot().0 == nil, "Unacknowledged save survived cleanup")
            brokenStore.configure()
            try await expectAuthenticationFailure(session(brokenStore))
            await broken.invalidate()
        }
        let retryStore = TestCredentialStore(), ready = session(retryStore)
        try await ready.install("dummy-retry", settings: settings, isDevelopmentBuild: true) { _ in }
        await ready.invalidate()
        retryStore.configure(.load)
        let retry = session(retryStore)
        try await expectAuthenticationFailure(retry)
        retryStore.configure()
        _ = try await retry.client(settings: settings, isDevelopmentBuild: true)
        await retry.invalidate()
        let failedCleanupStore = TestCredentialStore(); failedCleanupStore.configure(.saveAndCleanup)
        let failedCleanup = session(failedCleanupStore)
        var cleanupError: NSError?
        do {
            try await failedCleanup.install("dummy-cleanup-denied", settings: settings, isDevelopmentBuild: true) { _ in }
        } catch { cleanupError = error as NSError }
        try ensure(cleanupError?.userInfo["MyDriveCredentialCleanupError"] != nil,
                   "Cleanup denial discarded secondary failure evidence")
        try await expectAuthenticationFailure(failedCleanup)
        await failedCleanup.invalidate()
        print("PASS uncertain saves/readbacks fail closed; temporary store reads can retry")

        let cancelledStore = TestCredentialStore(), cancelled = session(cancelledStore)
        let began = VerificationCount()
        let pending = Task {
            try await cancelled.install("dummy-cancelled", settings: settings, isDevelopmentBuild: true) { _ in
                await began.increment(); try await Task.sleep(for: .seconds(10))
            }
        }
        while await began.value == 0 { await Task.yield() }
        pending.cancel()
        do { try await pending.value; throw SessionTestFailure(message: "Cancelled probe committed") }
        catch is CancellationError {}
        try ensure(cancelledStore.snapshot().0 == nil, "Cancelled verification persisted a credential")
        try await cancelled.install("dummy-ready", settings: settings, isDevelopmentBuild: true) { _ in }
        await cancelled.invalidate()
        try await expectFailure { _ = try await cancelled.client(settings: settings, isDevelopmentBuild: true) }
        try await expectFailure {
            try await cancelled.install("dummy-after-invalidation", settings: settings, isDevelopmentBuild: true) { _ in }
        }
        let cancelOnSave = TestCredentialStore()
        cancelOnSave.configure(onSave: { withUnsafeCurrentTask { $0?.cancel() } })
        let uncertain = session(cancelOnSave)
        let committing = Task {
            try await uncertain.install("dummy-commit-race", settings: settings, isDevelopmentBuild: true) { _ in }
        }
        do { try await committing.value; throw SessionTestFailure(message: "Cancelled save was acknowledged") }
        catch is CancellationError {}
        try ensure(cancelOnSave.snapshot().0 == nil, "Cancelled commit left an unacknowledged record")
        await uncertain.invalidate()
        print("PASS probe/save cancellation and invalidation cannot acknowledge stale credentials")

        let lookupStore = TestCredentialStore(), lookup = session(lookupStore), lookupLatch = VerificationLatch()
        let installing = Task {
            try await lookup.install("dummy-during-lookup", settings: settings, isDevelopmentBuild: true) { _ in
                await lookupLatch.wait(); try Task.checkCancellation()
            }
        }
        while !(await lookupLatch.started) { await Task.yield() }
        try await expectAuthenticationFailure(lookup)
        await lookupLatch.release()
        try await installing.value
        _ = try await lookup.client(settings: settings, isDevelopmentBuild: true)
        await lookup.invalidate()
        print("PASS concurrent Finder lookup cannot cancel in-flight credential verification")

        let validData = try unwrap(original)
        var invalidEnvelopes = [Data(repeating: 32, count: 32_769), Data("invalid-json".utf8)]
        let object = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        for field in ["buildID", "host", "share", "username", "domainID"] {
            var altered = object, scope = object["scope"] as! [String: Any]
            scope[field] = "different"; altered["scope"] = scope
            invalidEnvelopes.append(try JSONSerialization.data(withJSONObject: altered))
        }
        for data in invalidEnvelopes {
            let malformedStore = TestCredentialStore(); malformedStore.replace(data)
            let malformed = session(malformedStore)
            try await expectAuthenticationFailure(malformed)
            try ensure(malformedStore.snapshot().0 == nil, "Invalid envelope remained usable")
            await malformed.invalidate()
        }
        print("PASS bounded envelope decoding and endpoint/build binding reject retained invalid data")

        let scopedStore = KeyedCredentialStore()
        let a = try DevelopmentConnectionScope.settings(domainID: "b43ec727-a91a-4e8c-944a-269ffaf415c5")
        let b = try DevelopmentConnectionScope.settings(domainID: "4528f77f-133e-4f0c-9335-070c52d9aa12")
        let aSession = DevelopmentCredentialSession(store: scopedStore, buildIdentifier: { buildID })
        let bSession = DevelopmentCredentialSession(store: scopedStore, buildIdentifier: { buildID })
        try await aSession.install("dummy-A", settings: a, isDevelopmentBuild: true) { _ in }
        try await bSession.install("dummy-B", settings: b, isDevelopmentBuild: true) { _ in }
        let aData = try scopedStore.load(for: a), bData = try scopedStore.load(for: b)
        try ensure(aData != nil && bData != nil && aData != bData, "UUID domains shared one credential record")
        try await expectFailure { _ = try await aSession.client(settings: b, isDevelopmentBuild: true) }
        try await expectFailure { try await aSession.forget(settings: b, isDevelopmentBuild: true) }
        try await expectFailure { try await aSession.install("wrong", settings: b, isDevelopmentBuild: true) { _ in } }
        try ensure(try scopedStore.load(for: a) == aData && scopedStore.load(for: b) == bData,
                   "Cross-domain calls changed either record")
        try await aSession.forget(settings: a, isDevelopmentBuild: true)
        try ensure(try scopedStore.load(for: a) == nil && scopedStore.load(for: b) == bData, "Forgetting A removed B")
        await bSession.invalidate()
        let bRestarted = DevelopmentCredentialSession(store: scopedStore, buildIdentifier: { buildID })
        _ = try await bRestarted.client(settings: b, isDevelopmentBuild: true)
        for invalidID in [a.id.uppercased(), "../" + a.id, "arbitrary", ""] {
            let invalid = ConnectionSettings(domainID: invalidID, displayName: "Invalid", host: a.host, share: a.share, username: a.username)
            try await expectFailure { try await aSession.install("dummy", settings: invalid, isDevelopmentBuild: true) { _ in } }
        }
        await aSession.invalidate(); await bRestarted.invalidate()
        print("PASS canonical UUID sessions remain domain-bound across lookup, replacement, forget and restart")
        return 10
    }

    private static func unwrap(_ data: Data?) throws -> Data {
        guard let data else { throw SessionTestFailure(message: "Missing expected durable record") }
        return data
    }
    private static func expectAuthenticationFailure(_ session: DevelopmentCredentialSession) async throws {
        do {
            _ = try await session.client(settings: settings, isDevelopmentBuild: true)
            throw SessionTestFailure(message: "Unavailable provider record returned a client")
        } catch let error as NSFileProviderError where error.code == .notAuthenticated {}
    }
}
#endif
