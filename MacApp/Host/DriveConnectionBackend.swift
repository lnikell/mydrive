import AppKit
import FileProvider
import Foundation

enum DriveAction { case refresh, openFinder, keepSelected, offloadSelected, offloadAll }

/// The model owns operation lifetime and saved records. This boundary owns the
/// real framework/credential calls and always receives one immutable endpoint.
@MainActor protocol DriveConnectionBackend {
    func registeredDomainIDs() async throws -> Set<String>
    func verify(_ settings: ConnectionSettings, password: String) async throws
    func activate(_ settings: ConnectionSettings, password: String) async throws
    func perform(_ action: DriveAction, settings: ConnectionSettings) async throws -> String
    func remove(_ settings: ConnectionSettings, store: ConnectionStore) async throws -> ConnectionRemoval
}

@MainActor struct SystemDriveConnectionBackend: DriveConnectionBackend {
    func registeredDomainIDs() async throws -> Set<String> {
        Set(try await NSFileProviderManager.domains().map { $0.identifier.rawValue })
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
            if try await !registeredDomainIDs().contains(settings.domainID) { try await management.register() }
            try Task.checkCancellation()
            try await management.useDevelopmentCredential(password)
            try await management.connectionRestored()
            return
        }
        #endif
        try CredentialStore.save(password, for: settings)
        try Task.checkCancellation()
        if try await !registeredDomainIDs().contains(settings.domainID) { try await management.register() }
        try Task.checkCancellation()
        try await management.connectionRestored()
    }

    func perform(_ action: DriveAction, settings: ConnectionSettings) async throws -> String {
        let management = DomainManagement(settings: settings)
        switch action {
        case .refresh:
            try await management.refresh()
            return "Refreshed known folders."
        case .openFinder:
            guard NSWorkspace.shared.open(try await management.rootURL()) else { throw CocoaError(.fileReadUnknown) }
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
