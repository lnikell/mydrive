#if MYDRIVE_DEVELOPMENT
import Foundation
import FileProvider

/// The provider owns one expiring Keychain envelope. No operation falls back to
/// the host's credential, and loading never extends the original expiry.
actor DevelopmentCredentialSession {
    private let store: any DevelopmentCredentialPersistence
    private let buildIdentifier: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval
    private var loaded = false
    private var invalidated = false
    private var revision: UInt64 = 0
    private var record: DevelopmentCredentialRecord?
    private var deadline: ContinuousClock.Instant?
    private var expired = false
    private var verification: Task<Void, Error>?
    private var expiration: Task<Void, Never>?
    private var boundScope: DevelopmentCredentialScope?

    init(
        store: any DevelopmentCredentialPersistence = ProviderDevelopmentCredentialStore(),
        lifetime: Duration = .seconds(15 * 60),
        buildIdentifier: @escaping @Sendable () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "MyDriveDevelopmentCredentialBuildID") as? String
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.buildIdentifier = buildIdentifier
        self.now = now
        let parts = lifetime.components
        self.lifetime = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    func install(
        _ candidate: String, settings: ConnectionSettings, isDevelopmentBuild: Bool,
        verify: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        try checkActive()
        let scope = try scope(settings: settings, isDevelopmentBuild: isDevelopmentBuild)
        guard (1...4096).contains(candidate.utf8.count), lifetime > 0, lifetime <= 900 else {
            throw CocoaError(.fileReadNoPermission)
        }
        revision &+= 1
        let current = revision
        clearMemory()
        loaded = true
        // Explicit replacement must not resurrect an older record on restart.
        try store.remove(for: settings)
        let probe = Task { try await verify(candidate) }
        verification = probe
        do {
            try await withTaskCancellationHandler {
                try await probe.value
            } onCancel: { probe.cancel() }
            try checkActive()
            guard revision == current else { throw CancellationError() }
            verification = nil
            let created = now()
            let candidateRecord = DevelopmentCredentialRecord(
                version: 1, scope: scope, createdAt: created,
                expiresAt: created.addingTimeInterval(lifetime), password: candidate)
            let data = try JSONEncoder().encode(candidateRecord)
            guard (1...32_768).contains(data.count) else { throw SMBClientError.invalidResponse }
            try store.save(data, for: settings)
            try checkActive()
            guard try store.load(for: settings) == data else { throw SMBClientError.invalidResponse }
            try checkActive()
            try validate(candidateRecord, for: scope)
            activate(candidateRecord, revision: current)
        } catch {
            if revision == current {
                clearMemory()
                // A failed save/readback may have committed. Delete only our
                // exact build/endpoint record; do not acknowledge unknown data.
                throw removeAfterFailure(error, settings: settings)
            }
            throw error
        }
    }

    func client(settings: ConnectionSettings, isDevelopmentBuild: Bool) throws -> SMBClient {
        try checkActive()
        let expected: DevelopmentCredentialScope
        do { expected = try scope(settings: settings, isDevelopmentBuild: isDevelopmentBuild) }
        catch { throw authenticationFailure(error) }
        // Finder may ask for clients while installation awaits SMB. It must
        // not cancel that verifier or revive an older durable credential.
        if verification != nil { throw authenticationFailure() }
        if !loaded {
            // A temporarily locked/unavailable Keychain is retryable. Do not
            // delete an unread record or cache that store error as missing.
            let data: Data?
            do { data = try store.load(for: settings) }
            catch { throw authenticationFailure(error) }
            guard let data else {
                loaded = true
                throw authenticationFailure()
            }
            let saved: DevelopmentCredentialRecord
            do {
                guard (1...32_768).contains(data.count) else { throw SMBClientError.invalidResponse }
                saved = try JSONDecoder().decode(DevelopmentCredentialRecord.self, from: data)
                try validate(saved, for: expected)
            } catch {
                loaded = true
                clearMemory()
                throw authenticationFailure(removeAfterFailure(error, settings: settings))
            }
            try checkActive()
            loaded = true
            activate(saved, revision: revision)
        }
        guard let record, let deadline else {
            if expired {
                throw authenticationFailure(removeAfterFailure(
                    SMBClientError.authenticationRequired, settings: settings))
            }
            throw authenticationFailure()
        }
        guard ContinuousClock().now < deadline, now() < record.expiresAt else {
            clearMemory()
            expired = true
            throw authenticationFailure(removeAfterFailure(
                SMBClientError.authenticationRequired, settings: settings))
        }
        return SMBClient(settings: settings, developmentPassword: record.password)
    }

    func forget(settings: ConnectionSettings, isDevelopmentBuild: Bool) throws {
        try checkActive()
        _ = try scope(settings: settings, isDevelopmentBuild: isDevelopmentBuild)
        revision &+= 1
        loaded = true
        clearMemory()
        try store.remove(for: settings)
    }

    /// Invalidation cancels memory/work but lets the same build restart before
    /// the original absolute expiry and read its own durable record.
    func invalidate() {
        invalidated = true
        revision &+= 1
        clearMemory()
    }

    private func activate(_ value: DevelopmentCredentialRecord, revision current: UInt64) {
        record = value
        expired = false
        let remaining = max(0, value.expiresAt.timeIntervalSince(now()))
        let expires = ContinuousClock().now.advanced(by: .seconds(remaining))
        deadline = expires
        expiration = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: expires)
                await self?.expire(revision: current)
            } catch { /* Replacement or invalidation owns cancellation. */ }
        }
    }

    private func expire(revision expected: UInt64) {
        guard revision == expected else { return }
        // Delete lazily on lookup. This timer captures no settings or secret;
        // the durable envelope already carries its absolute expired deadline.
        clearMemory()
        expired = true
    }

    private func clearMemory() {
        record = nil
        deadline = nil
        expired = false
        verification?.cancel()
        verification = nil
        expiration?.cancel()
        expiration = nil
    }

    private func validate(_ value: DevelopmentCredentialRecord, for scope: DevelopmentCredentialScope) throws {
        let duration = value.expiresAt.timeIntervalSince(value.createdAt)
        let current = now()
        guard value.version == 1, value.scope == scope,
              (1...4096).contains(value.password.utf8.count),
              value.createdAt.timeIntervalSinceReferenceDate.isFinite,
              value.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              duration > 0, duration <= 900,
              value.createdAt <= current, current < value.expiresAt else {
            throw SMBClientError.authenticationRequired
        }
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if invalidated { throw CancellationError() }
    }

    private func authenticationFailure(_ underlying: Error? = nil) -> NSFileProviderError {
        NSFileProviderError(.notAuthenticated,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }

    private func removeAfterFailure(_ error: Error, settings: ConnectionSettings) -> Error {
        do { try store.remove(for: settings); return error }
        catch let cleanup {
            let original = error is CancellationError ? CocoaError(.userCancelled) as NSError : error as NSError
            var details = original.userInfo
            details[NSUnderlyingErrorKey] = original
            details["MyDriveCredentialCleanupError"] = cleanup as NSError
            return NSError(domain: original.domain, code: original.code, userInfo: details)
        }
    }

    private func scope(settings: ConnectionSettings, isDevelopmentBuild: Bool) throws -> DevelopmentCredentialScope {
        try DevelopmentConnectionScope.validate(settings)
        guard isDevelopmentBuild,
              let raw = buildIdentifier(), raw.count == 36, let uuid = UUID(uuidString: raw),
              uuid.uuidString.caseInsensitiveCompare(raw) == .orderedSame else {
            throw CocoaError(.fileReadNoPermission)
        }
        let requested = DevelopmentCredentialScope(buildID: uuid.uuidString.lowercased(), domainID: settings.domainID,
            host: settings.host, share: settings.share, username: settings.username)
        guard boundScope == nil || boundScope == requested else { throw CocoaError(.fileReadNoPermission) }
        boundScope = requested
        return requested
    }
}
#endif
