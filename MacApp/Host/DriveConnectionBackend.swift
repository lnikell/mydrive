import AppKit
import FileProvider
import Foundation
import Network

enum DriveAction { case refresh, openFinder, keepSelected, offloadSelected, offloadAll, clearCache, keepAll, pause, resume, rebuild }
enum LibraryAction { case showFinder, keepDownloaded, freeUpSpace }

/// The model owns operation lifetime and saved records. This boundary owns the
/// real framework/credential calls and always receives one immutable endpoint.
@MainActor protocol DriveConnectionBackend {
    func registeredDomainIDs() async throws -> Set<String>
    func verify(_ settings: ConnectionSettings, password: String) async throws
    func verifyReachability(_ settings: ConnectionSettings) async throws
    func activate(_ settings: ConnectionSettings, password: String) async throws
    func perform(_ action: DriveAction, settings: ConnectionSettings) async throws -> String
    func remove(_ settings: ConnectionSettings, store: ConnectionStore) async throws -> ConnectionRemoval
    func disconnectedDomainIDs() async throws -> Set<String>
    func snapshot(_ settings: ConnectionSettings, measureCache: Bool) async throws -> ProviderSnapshot
    func library(_ settings: ConnectionSettings, scope: LibraryScope, afterID: String?, generation: Int64?) async throws -> LibraryPage
    func perform(_ action: LibraryAction, itemID: String, settings: ConnectionSettings) async throws
    func setVisible(_ visible: Bool, settings: ConnectionSettings) async throws
}

extension DriveConnectionBackend {
    func verifyReachability(_ settings: ConnectionSettings) async throws {}
    func disconnectedDomainIDs() async throws -> Set<String> { [] }
    func snapshot(_ settings: ConnectionSettings, measureCache: Bool) async throws -> ProviderSnapshot { throw CocoaError(.featureUnsupported) }
    func library(_ settings: ConnectionSettings, scope: LibraryScope, afterID: String?, generation: Int64?) async throws -> LibraryPage { throw CocoaError(.featureUnsupported) }
    func perform(_ action: LibraryAction, itemID: String, settings: ConnectionSettings) async throws { throw CocoaError(.featureUnsupported) }
    func setVisible(_ visible: Bool, settings: ConnectionSettings) async throws { throw CocoaError(.featureUnsupported) }
}

@MainActor struct SystemDriveConnectionBackend: DriveConnectionBackend {
    func verifyReachability(_ settings: ConnectionSettings) async throws {
        let address = try SMBAddress(server: settings.host, share: settings.share)
        guard let parsed = URLComponents(string: "smb://" + address.endpoint), let host = parsed.host,
              let port = NWEndpoint.Port(rawValue: UInt16(parsed.port ?? 445)) else { throw SMBClientError.serverUnreachable }
        let connection = NWConnection(host: NWEndpoint.Host(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))), port: port, using: .tcp)
        let request = DomainControlOperation<Void>(timeout: 10)
        defer { connection.cancel() }
        do {
            try await request.run {
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: request.finish(.success(()))
                    case .failed: request.finish(.failure(SMBClientError.serverUnreachable))
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue(label: "local.mydrive.reachability"))
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw SMBClientError.serverUnreachable }
    }
    func setVisible(_ visible: Bool, settings: ConnectionSettings) async throws {
        let management = DomainManagement(settings: settings)
        let paused = try await disconnectedDomainIDs().contains(settings.domainID)
        try await management.register(hidden: !visible)
        if paused { try await management.setPaused(true) }
    }
    func registeredDomainIDs() async throws -> Set<String> {
        Set(try await NSFileProviderManager.domains().map { $0.identifier.rawValue })
    }

    func disconnectedDomainIDs() async throws -> Set<String> {
        Set(try await NSFileProviderManager.domains().filter(\.isDisconnected).map { $0.identifier.rawValue })
    }

    func snapshot(_ settings: ConnectionSettings, measureCache: Bool) async throws -> ProviderSnapshot {
        try await DomainManagement(settings: settings).snapshot(measureCache: measureCache)
    }

    func library(_ settings: ConnectionSettings, scope: LibraryScope, afterID: String?, generation: Int64?) async throws -> LibraryPage {
        try await DomainManagement(settings: settings).library(scope: scope, afterID: afterID, generation: generation)
    }

    func perform(_ action: LibraryAction, itemID: String, settings: ConnectionSettings) async throws {
        let management = DomainManagement(settings: settings)
        switch action {
        case .showFinder: try await management.showItem(itemID)
        case .keepDownloaded: try await management.keepDownloaded([itemID == "root" ? NSFileProviderItemIdentifier.rootContainer.rawValue : itemID])
        case .freeUpSpace: _ = try await management.offload([itemID == "root" ? NSFileProviderItemIdentifier.rootContainer.rawValue : itemID])
        }
    }

    func verify(_ settings: ConnectionSettings, password: String) async throws {
        try ConnectionStore.validate(settings)
        guard (1...4096).contains(password.utf8.count) else { throw SMBClientError.authenticationRequired }
        #if MYDRIVE_DEVELOPMENT
        if AppStorage.isDevelopmentStorage { try DevelopmentConnectionScope.validate(settings) }
        #endif
        try await SMBClient(settings: settings).probe(password: password)
    }

    func activate(_ settings: ConnectionSettings, password: String) async throws {
        try Task.checkCancellation()
        let management = DomainManagement(settings: settings)
        #if MYDRIVE_DEVELOPMENT
        if AppStorage.isDevelopmentStorage {
            try DevelopmentConnectionScope.validate(settings)
            if try await disconnectedDomainIDs().contains(settings.domainID) { try await management.setPaused(false) }
            try await Self.activateDevelopment(
                isRegistered: { try await registeredDomainIDs().contains(settings.domainID) },
                register: { try await management.register(hidden: $0) },
                installCredential: { try await management.useDevelopmentCredential(password) },
                connectionRestored: { try await management.connectionRestored() })
            return
        }
        #endif
        try CredentialStore.save(password, for: settings)
        try Task.checkCancellation()
        if try await !registeredDomainIDs().contains(settings.domainID) {
            try await management.register(hidden: !AppStorage.preferences(for: settings.domainID).showFinder)
        }
        try await management.setPaused(false)
        try Task.checkCancellation()
        try await management.connectionRestored()
    }

    #if MYDRIVE_DEVELOPMENT
    /// The provider owns development credentials, so a new location must stay
    /// hidden until that same domain has confirmed it can enumerate the NAS.
    /// Side effects are injected only at this internal lifecycle test seam.
    static func activateDevelopment(
        isRegistered: () async throws -> Bool,
        register: (Bool) async throws -> Void,
        installCredential: () async throws -> Void,
        connectionRestored: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let registered = try await isRegistered()
        try Task.checkCancellation()
        if !registered { try await register(true) }
        try Task.checkCancellation()
        try await installCredential()
        try Task.checkCancellation()
        try await connectionRestored()
        try Task.checkCancellation()
        // Re-adding the same ID also reveals a hidden registration whose prior
        // activation failed. A failure above never publishes an unready drive.
        try await register(false)
    }
    #endif

    func perform(_ action: DriveAction, settings: ConnectionSettings) async throws -> String {
        let management = DomainManagement(settings: settings)
        switch action {
        case .refresh:
            try await management.refresh()
            return "Refreshed known folders."
        case .openFinder:
            let url = try await management.rootURL()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Finder could not open this drive."])
            }
            return ""
        case .keepSelected:
            let items = try await management.selectItems()
            guard !items.isEmpty else { return "No files selected." }
            try await management.keepDownloaded(items)
            return "Requested offline availability. Finder shows download progress."
        case .offloadSelected:
            let items = try await management.selectItems()
            return try await management.offload(items)
        case .offloadAll:
            return try await management.offload()
        case .clearCache:
            return try await management.offload(preservingOffline: true)
        case .keepAll:
            try await management.keepDownloaded([NSFileProviderItemIdentifier.rootContainer.rawValue])
            return "Requested offline availability for this mount. Finder shows download progress."
        case .pause:
            try await management.setPaused(true)
            return "Syncing paused. Local files are kept."
        case .resume:
            try await management.setPaused(false)
            return "Syncing resumed."
        case .rebuild:
            let registered = try await registeredDomainIDs().contains(settings.domainID)
            let paused = try await disconnectedDomainIDs().contains(settings.domainID)
            if !registered {
                guard !AppStorage.isDevelopmentStorage else { throw SMBClientError.authenticationRequired }
                let password = try CredentialStore.password(for: settings, allowInteraction: false)
                try await verify(settings, password: password)
            }
            try await management.register(hidden: !AppStorage.preferences(for: settings.domainID).showFinder)
            if paused { try await management.setPaused(true) }
            else { try await management.connectionRestored() }
            return "Finder integration rebuilt. Cached files are kept."
        }
    }

    func remove(_ settings: ConnectionSettings, store: ConnectionStore) async throws -> ConnectionRemoval {
        // Reconcile again at removal time: a failed registration may already
        // have been accepted by macOS, and a stale UI flag is not proof.
        if try await registeredDomainIDs().contains(settings.domainID) {
            return try await DomainManagement(settings: settings).remove()
        }
        try Task.checkCancellation()
        var failures: [String] = []
        do { try CredentialStore.remove(for: settings) }
        catch { failures.append("Saved credentials: \(error.localizedDescription)") }
        var retained: URL?
        do { retained = try store.removeUnregisteredSettings(settings) }
        catch { failures.append("Connection settings: \(error.localizedDescription)") }
        if retained != nil { failures.append("Existing local drive data was retained because this drive is no longer registered.") }
        return ConnectionRemoval(preservedURL: retained, cleanupFailures: failures)
    }
}
