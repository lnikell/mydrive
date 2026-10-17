import AppKit
import FileProvider
import Foundation

struct ConnectionRemoval {
    let preservedURL: URL?
    let cleanupFailures: [String]
    var recoveryURLs: [URL] = []
}

@MainActor final class DomainManagement {
    let settings: ConnectionSettings
    var domain: NSFileProviderDomain {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(settings.domainID),
                                          displayName: settings.displayName)
        domain.supportsSyncingTrash = false
        return domain
    }

    init(settings: ConnectionSettings) { self.settings = settings }

    func register() async throws {
        try await NSFileProviderManager.add(domain)
    }

    /// A provider refresh must confirm its own credential and connection work;
    /// a successful host probe or registration alone cannot establish that.
    func connectionRestored() async throws {
        guard let manager = NSFileProviderManager(for: domain) else { throw SMBClientError.invalidResponse }
        try Task.checkCancellation()
        try await refresh()
        try Task.checkCancellation()
        try await manager.signalErrorResolved(NSFileProviderError(.notAuthenticated))
        try Task.checkCancellation()
        try await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable))
    }

    #if MYDRIVE_DEVELOPMENT
    func registerIfNeeded() async throws {
        let domains = try await NSFileProviderManager.domains()
        if !domains.contains(where: { $0.identifier == domain.identifier }) { try await register() }
    }

    func useDevelopmentCredential(_ password: String) async throws {
        guard AppStorage.isDevelopmentStorage, !password.isEmpty, password.utf8.count <= 4096 else {
            throw CocoaError(.fileReadNoPermission)
        }
        try await control { proxy, reply in
            proxy.useDevelopmentCredential(password) { @Sendable error in
                reply(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    private func forgetDevelopmentCredential() async throws {
        guard AppStorage.isDevelopmentStorage else { throw CocoaError(.featureUnsupported) }
        try await control { proxy, reply in
            proxy.forgetDevelopmentCredential { @Sendable error in
                reply(error.map { .failure($0) } ?? .success(()))
            }
        }
    }
    #endif

    func rootURL() async throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else { throw SMBClientError.invalidResponse }
        return try await manager.getUserVisibleURL(for: .rootContainer)
    }

    func selectItems() async throws -> [String] {
        let panel = NSOpenPanel()
        panel.directoryURL = try await rootURL()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        guard await panel.begin() == .OK else { return [] }
        var identifiers: [String] = []
        for url in panel.urls {
            let result: (NSFileProviderItemIdentifier, NSFileProviderDomainIdentifier) = try await withCheckedThrowingContinuation { continuation in
                NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { @Sendable item, domain, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let item, let domain { continuation.resume(returning: (item, domain)) }
                    else { continuation.resume(throwing: SMBClientError.invalidResponse) }
                }
            }
            guard result.1.rawValue == settings.domainID else {
                throw CocoaError(.fileReadNoPermission)
            }
            identifiers.append(result.0.rawValue)
        }
        return identifiers
    }

    func keepDownloaded(_ identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        try await control { proxy, reply in
            proxy.keepDownloaded(identifiers) { @Sendable error in
                reply(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    func refresh() async throws {
        try await control { proxy, reply in
            proxy.refresh { @Sendable error in
                reply(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    func offload(_ identifiers: [String]? = nil) async throws -> String {
        if let identifiers, identifiers.isEmpty { return "No files selected." }
        let result: (Int, [String], NSError?) = try await control { proxy, complete in
            let reply: @Sendable (Int, [String], NSError?) -> Void = { count, retained, error in
                complete(.success((count, retained, error)))
            }
            if let identifiers { proxy.freeUpSpace(identifiers, reply: reply) }
            else { proxy.freeUpAllSpace(reply: reply) }
        }
        let summary = "Freed local downloads for \(result.0) \(result.0 == 1 ? "file" : "files"). NAS originals are retained."
        // These are bounded diagnostics, possibly ending with an omitted-item
        // summary. Their array count is not the number of retained files.
        let retained = result.1.isEmpty ? "" : "\nSome downloads remain:\n" + result.1.joined(separator: "\n")
        guard let failure = result.2 else { return summary + retained }
        var details = failure.userInfo
        details[NSLocalizedDescriptionKey] = summary + "\nFree Up Space could not finish: " + failure.localizedDescription + retained
        details[NSUnderlyingErrorKey] = failure
        details["MyDriveCompletedEvictions"] = result.0
        details["MyDriveRetainedItems"] = result.1
        if !result.1.isEmpty { details[NSLocalizedFailureReasonErrorKey] = result.1.joined(separator: "\n") }
        throw NSError(domain: failure.domain, code: failure.code, userInfo: details)
    }

    /// Explicit OS removal preserves unsynced work and removes clean downloads.
    /// Forget provider-owned development credentials before its endpoint is lost;
    /// host configuration is removed after File Provider confirms success.
    func remove() async throws -> ConnectionRemoval {
        try Task.checkCancellation()
        var failures: [String] = []
        #if MYDRIVE_DEVELOPMENT
        if AppStorage.isDevelopmentStorage {
            do { try await forgetDevelopmentCredential() }
            catch { failures.append("Provider development credentials: \(error.localizedDescription)") }
        }
        #endif
        let preserved: URL?
        do {
            try Task.checkCancellation()
            preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData)
        } catch {
            guard !failures.isEmpty else { throw error }
            let failure = error as NSError
            var details = failure.userInfo
            details[NSLocalizedDescriptionKey] = failure.localizedDescription +
                "\nCredential cleanup also needs attention: " + failures.joined(separator: "\n")
            details[NSUnderlyingErrorKey] = failure
            details["MyDriveCleanupFailures"] = failures
            throw NSError(domain: failure.domain, code: failure.code, userInfo: details)
        }
        // OS removal has already succeeded. Cleanup failures must never hide
        // the URL of pending local work that macOS chose to preserve.
        do { try CredentialStore.remove(for: settings) }
        catch { failures.append("Saved credentials: \(error.localizedDescription)") }
        var recovery: [URL] = []
        do {
            let store = try AppStorage.connectionStore()
            if let preserved {
                do { try store.retainedWorkLocations.record(preserved, domainID: settings.domainID) }
                catch { failures.append("Retained-work shortcut could not be saved: \(error.localizedDescription)") }
            }
            let folder = try store.folder(for: settings.domainID)
            do {
                if let retained = try await ConnectionRemovalStorage.clean(folder: folder, preserving: preserved) {
                    recovery.append(retained)
                }
            } catch {
                recovery.append(folder)
                throw error
            }
        } catch { failures.append("Local recovery data retained: \(error.localizedDescription)") }
        return ConnectionRemoval(preservedURL: preserved, cleanupFailures: failures, recoveryURLs: recovery)
    }

    private func control<Value: Sendable>(
        request: @escaping @MainActor @Sendable (DomainControlProtocol, @escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        guard let manager = NSFileProviderManager(for: domain) else { throw SMBClientError.invalidResponse }
        let operation = DomainControlOperation<Value>()
        return try await operation.run { [weak operation] in
            do {
                guard let service = try await manager.service(named: domainControlServiceName, for: .rootContainer) else {
                    throw DomainControlError.unavailable
                }
                try Task.checkCancellation()
                service.getFileProviderConnection { @Sendable [weak operation] connection, error in
                    guard let operation else { connection?.invalidate(); return }
                    if let error {
                        connection?.invalidate()
                        operation.finish(.failure(error), phase: .connectionAcquisition)
                    } else if let connection {
                        operation.connect(connection, request: request)
                    } else {
                        operation.finish(.failure(SMBClientError.invalidResponse), phase: .connectionAcquisition)
                    }
                }
            } catch {
                operation?.finish(.failure(error), phase: .serviceLookup)
            }
        }
    }
}

/// One service request owns its continuation, connection and deadline. XPC
/// failures, cancellation and duplicate/late replies all race through finish().
/// Cancellation ends local waiting; it cannot roll back work already accepted
/// by the provider. Every mutable field is protected by lock.
final class DomainControlOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var connection: NSXPCConnection?
    private var resolver: Task<Void, Never>?
    private var deadline: DispatchWorkItem?
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 120) { self.timeout = timeout }

    @MainActor func run(_ resolve: @escaping @MainActor @Sendable () async -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed: Result<Value, Error>? = lock.withLock {
                    if let terminal { return terminal }
                    self.continuation = continuation
                    return nil
                }
                if let completed {
                    continuation.resume(with: completed)
                    return
                }
                let timer = DispatchWorkItem { @Sendable [weak self] in
                    self?.finish(.failure(DomainControlError.timedOut), phase: .deadline)
                }
                let resolver = Task { @MainActor in await resolve() }
                let active = lock.withLock {
                    guard terminal == nil else { return false }
                    self.deadline = timer
                    self.resolver = resolver
                    return true
                }
                if active {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                } else {
                    timer.cancel()
                    resolver.cancel()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func connect(
        _ connection: NSXPCConnection,
        request: @escaping @MainActor @Sendable (DomainControlProtocol, @escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) {
        let accepted = lock.withLock {
            guard terminal == nil, self.connection == nil else { return false }
            self.connection = connection
            return true
        }
        guard accepted else { connection.invalidate(); return }
        Task { @MainActor [weak self] in self?.send(request) }
    }

    @MainActor private func send(
        _ request: @MainActor @Sendable (DomainControlProtocol, @escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) {
        guard let connection = lock.withLock({ terminal == nil ? self.connection : nil }) else { return }
        connection.remoteObjectInterface = NSXPCInterface(with: DomainControlProtocol.self)
        connection.interruptionHandler = { @Sendable [weak self] in
            self?.finish(.failure(DomainControlError.unavailable), phase: .requestTransport)
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            self?.finish(.failure(DomainControlError.unavailable), phase: .requestTransport)
        }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
            self?.finish(.failure(error), phase: .requestTransport)
        }) as? DomainControlProtocol else {
            finish(.failure(SMBClientError.invalidResponse), phase: .requestTransport)
            return
        }
        request(proxy) { [weak self] in self?.finish($0, phase: .providerReply) }
    }

    func finish(_ outcome: Result<Value, Error>, phase: DomainControlPhase? = nil) {
        let result = outcome.mapError { phase?.annotating($0) ?? $0 }
        let owned = lock.withLock { () -> (CheckedContinuation<Value, Error>?, NSXPCConnection?, Task<Void, Never>?, DispatchWorkItem?)? in
            guard terminal == nil else { return nil }
            terminal = result
            defer {
                continuation = nil
                connection = nil
                resolver = nil
                deadline = nil
            }
            return (continuation, connection, resolver, deadline)
        }
        guard let owned else { return }
        owned.3?.cancel()
        owned.2?.cancel()
        owned.1?.invalidate()
        owned.0?.resume(with: result)
    }
}

/// A transport error after dispatch does not reveal whether the provider
/// accepted a request. These diagnostics never authorize replaying it.
enum DomainControlPhase: String, Sendable, CaseIterable {
    case serviceLookup = "service_lookup"
    case connectionAcquisition = "connection_acquisition"
    case requestTransport = "request_transport"
    case providerReply = "provider_reply"
    case deadline

    fileprivate func annotating(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        let original = error as NSError
        var details = original.userInfo
        details["MyDriveControlPhase"] = rawValue
        details[NSLocalizedDescriptionKey] = original.localizedDescription
        details[NSUnderlyingErrorKey] = original
        return NSError(domain: original.domain, code: original.code, userInfo: details)
    }
}

private enum DomainControlError: LocalizedError {
    case unavailable, timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: "The Finder connection ended. Try the operation again."
        case .timedOut: "Finder did not finish this request in time. Try again after its current work completes."
        }
    }
}
