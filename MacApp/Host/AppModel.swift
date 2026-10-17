import Foundation
import Observation

@MainActor @Observable final class AppModel {
    private(set) var drives: [DriveModel] = []
    private(set) var loadIssues: [ConnectionLoadIssue] = []
    private(set) var status = ""
    private(set) var busy = true
    private let storage: Result<ConnectionStore, Error>
    private let backend: any DriveConnectionBackend
    private let makeMonitor: @MainActor () -> ConnectionMonitor
    private let diagnosticLaunch: Bool
    private var started = false

    init(store: Result<ConnectionStore, Error>? = nil,
         backend: any DriveConnectionBackend = SystemDriveConnectionBackend(),
         makeMonitor: @escaping @MainActor () -> ConnectionMonitor = { ConnectionMonitor() },
         launchArguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        storage = store ?? Result { try AppStorage.connectionStore() }
        self.backend = backend
        self.makeMonitor = makeMonitor
        diagnosticLaunch = launchArguments.contains { $0.hasPrefix("--probe-") }
    }

    func startup() async {
        guard !started, !diagnosticLaunch else { return }
        started = true
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            let store = try storage.get(), saved = try store.load()
            loadIssues = saved.issues
            let registered: Set<String>
            do { registered = try await backend.registeredDomainIDs() }
            catch is CancellationError { throw CancellationError() }
            catch {
                registered = []
                loadIssues.append(ConnectionLoadIssue(id: "registration", message:
                    "Finder registration status could not be read: \(error.localizedDescription)"))
            }
            try Task.checkCancellation()
            drives = saved.connections.map {
                DriveModel(settings: $0, isRegistered: registered.contains($0.domainID),
                           store: store, backend: backend, monitor: makeMonitor())
            }
            let savedIDs = Set(saved.connections.map(\.domainID))
            for id in registered.subtracting(savedIDs).sorted() {
                loadIssues.append(ConnectionLoadIssue(id: "missing-" + id,
                    message: "A Finder drive has no readable saved connection (\(id)). Its local data was retained."))
            }
            for drive in drives {
                try Task.checkCancellation()
                await drive.startMonitoring()
            }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                for drive in drives { await drive.stopMonitoring() }
                started = false
            } else { status = error.localizedDescription }
        }
    }

    func makeDraft() -> ConnectionSettings {
        let id = UUID().uuidString.lowercased()
        #if MYDRIVE_DEVELOPMENT
        if AppStorage.isDevelopmentStorage, let draft = try? DevelopmentConnectionScope.settings(domainID: id) {
            return draft
        }
        #endif
        return ConnectionSettings(domainID: id, displayName: "", host: "", share: "", username: "")
    }

    func add(_ settings: ConnectionSettings, password: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let store = try storage.get()
            try ConnectionStore.validate(settings)
            if let existing = drives.first(where: { $0.id == settings.domainID }) {
                guard existing.settings == settings else { throw ConnectionStoreError.endpointChanged }
                let connected = await existing.reconnect(password: password)
                status = connected ? "Connected \(existing.name)." : existing.status
                return connected
            }
            guard try store.existingSettings(for: settings.domainID) == nil else {
                throw ConnectionStoreError.endpointChanged
            }
            let drive = DriveModel(settings: settings, isRegistered: false,
                                   store: store, backend: backend, monitor: makeMonitor())
            let connected = await drive.reconnect(password: password)
            if (try store.existingSettings(for: settings.domainID)) != nil { drives.append(drive) }
            status = connected ? "Added \(drive.name)." : drive.status
            return connected
        } catch { status = error.localizedDescription; return false }
    }

    func remove(_ drive: DriveModel) async -> Bool {
        guard drives.contains(where: { $0 === drive }), let result = await drive.removeConnection() else { return false }
        drives.removeAll { $0 === drive }
        var message = "Disconnected \(drive.name). NAS originals are retained."
        if let preserved = result.preservedURL { message += "\nLocal work retained at: \(preserved.path)" }
        if !result.cleanupFailures.isEmpty { message += "\nCleanup needs attention:\n" + result.cleanupFailures.joined(separator: "\n") }
        status = message
        return true
    }

    func shutdown() async { for drive in drives { await drive.stopMonitoring() } }
}
