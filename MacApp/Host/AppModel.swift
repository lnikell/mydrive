import Foundation
import Observation

struct UninstallPreparation {
    var attempted = false
    var currentDrive: String?
    var issues: [String] = []
    var verifiedNoDomains = false
    var ready: Bool { attempted && verifiedNoDomains && issues.isEmpty }
}

@MainActor @Observable final class AppModel {
    private(set) var drives: [DriveModel] = []
    private(set) var loadIssues: [ConnectionLoadIssue] = []
    private(set) var status = ""
    private(set) var retainedWork: [URL] = []
    private(set) var busy = true
    private(set) var preparingUninstall = false
    private(set) var uninstall = UninstallPreparation()
    /// The drive being connected by `add`, so its progress can be shown.
    private(set) var connecting: DriveModel?
    /// Why the last `add` failed, if it did.
    private(set) var addFailure: (any Error)?
    private let storage: Result<ConnectionStore, Error>
    private let backend: any DriveConnectionBackend
    private let makeMonitor: @MainActor () -> ConnectionMonitor
    private let diagnosticLaunch: Bool
    private var started = false
    private var removalWarnings: [String] = []

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
            retainedWork = saved.retainedFolders
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
        uninstall.verifiedNoDomains = false
        busy = true
        addFailure = nil
        defer { busy = false; connecting = nil }
        do {
            let store = try storage.get()
            try ConnectionStore.validate(settings)
            if let existing = drives.first(where: { $0.id == settings.domainID }) {
                guard existing.settings == settings else { throw ConnectionStoreError.endpointChanged }
                connecting = existing
                let connected = await existing.reconnect(password: password)
                status = connected ? "Connected \(existing.name)." : existing.status
                if !connected { addFailure = existing.connectFailure }
                return connected
            }
            guard try store.existingSettings(for: settings.domainID) == nil else {
                throw ConnectionStoreError.endpointChanged
            }
            let drive = DriveModel(settings: settings, isRegistered: false,
                                   store: store, backend: backend, monitor: makeMonitor())
            connecting = drive
            let connected = await drive.reconnect(password: password)
            if (try store.existingSettings(for: settings.domainID)) != nil { drives.append(drive) }
            status = connected ? "Added \(drive.name)." : drive.status
            if !connected { addFailure = drive.connectFailure }
            return connected
        } catch {
            addFailure = error
            status = error.localizedDescription
            return false
        }
    }

    func remove(_ drive: DriveModel) async -> Bool {
        guard !busy, drives.contains(where: { $0 === drive }),
              let result = await drive.removeConnection() else { return false }
        uninstall.verifiedNoDomains = false
        finishRemoval(drive, result: result)
        return true
    }

    func reconnect(_ drive: DriveModel, password: String) async -> Bool {
        guard !busy, drives.contains(where: { $0 === drive }) else { return false }
        uninstall.verifiedNoDomains = false
        return await drive.reconnect(password: password)
    }

    func perform(_ action: DriveAction, on drive: DriveModel) async {
        guard !busy, drives.contains(where: { $0 === drive }) else { return }
        switch action {
        case .refresh: await drive.refresh()
        case .openFinder: await drive.openFinder()
        case .keepSelected: await drive.keepSelected()
        case .offloadSelected: await drive.offloadSelected()
        case .offloadAll: await drive.offloadAll()
        }
    }

    /// One user action owns the sequential removals. DriveModel remains the
    /// sole removal/monitor owner; this module aggregates evidence and checks
    /// the real framework state before describing uninstall as ready.
    func prepareForUninstall() async {
        guard !busy, !drives.contains(where: \.busy) else {
            if !preparingUninstall {
                uninstall = UninstallPreparation(attempted: true,
                    issues: ["Wait for the current drive operation to finish, then try again."])
            }
            return
        }
        busy = true; preparingUninstall = true
        uninstall = UninstallPreparation(attempted: true)
        defer { busy = false; preparingUninstall = false; uninstall.currentDrive = nil }
        for drive in drives {
            if Task.isCancelled { break }
            uninstall.currentDrive = drive.name
            if let result = await drive.removeConnection() { finishRemoval(drive, result: result) }
            else { uninstall.issues.append("\(drive.name): \(drive.status)") }
        }
        if Task.isCancelled { uninstall.issues.append("Preparation was cancelled. Remaining drives are still connected.") }
        uninstall.currentDrive = nil
        // Refresh discovery: old startup warnings cannot prove that a record
        // or an unknown domain has since been repaired or removed.
        do {
            let saved = try storage.get().load()
            loadIssues = saved.issues
            for location in saved.retainedFolders where !retainedWork.contains(location) { retainedWork.append(location) }
            uninstall.issues += saved.issues.map(\.message)
            if !saved.connections.isEmpty { uninstall.issues.append("Some saved drives still need to be disconnected.") }
        } catch {
            uninstall.issues.append("Saved connections could not be checked: \(error.localizedDescription)")
        }
        do {
            let registered = try await backend.registeredDomainIDs()
            uninstall.verifiedNoDomains = registered.isEmpty
            if !registered.isEmpty {
                uninstall.issues.append("Finder still has \(registered.count) MyDrive drive(s). Reconnect missing saved drives or resolve Saved Drive Issues before uninstalling.")
                let known = Set(drives.map(\.id))
                for id in registered.subtracting(known).sorted() {
                    let issue = ConnectionLoadIssue(id: "missing-" + id,
                        message: "A Finder drive has no readable saved connection (\(id)). Its local data was retained.")
                    loadIssues.append(issue); uninstall.issues.append(issue.message)
                }
            }
        } catch {
            uninstall.issues.append("Finder drive registrations could not be checked: \(error.localizedDescription)")
        }
        uninstall.issues += removalWarnings.filter { !uninstall.issues.contains($0) }
        status = uninstall.ready ? "All MyDrive drives are disconnected. NAS originals are kept." :
            "Uninstall preparation needs attention. Review the details and any retained local work."
    }

    private func finishRemoval(_ drive: DriveModel, result: ConnectionRemoval) {
        drives.removeAll { $0 === drive }
        var message = "Disconnected \(drive.name). NAS originals are retained."
        for location in [result.preservedURL].compactMap({ $0 }) + result.recoveryURLs
            where !retainedWork.contains(location) { retainedWork.append(location) }
        if let preserved = result.preservedURL { message += "\nLocal work retained at: \(preserved.path)" }
        for recovery in result.recoveryURLs { message += "\nUpload recovery data retained at: \(recovery.path)" }
        if !result.cleanupFailures.isEmpty {
            message += "\nCleanup needs attention:\n" + result.cleanupFailures.joined(separator: "\n")
            for failure in result.cleanupFailures {
                let warning = "\(drive.name): \(failure)"
                if !removalWarnings.contains(warning) { removalWarnings.append(warning) }
            }
        }
        status = message
    }

    func shutdown() async { for drive in drives { await drive.stopMonitoring() } }
}
