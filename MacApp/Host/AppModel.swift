import Foundation
import Observation

struct UninstallPreparation {
    var attempted = false
    var currentDrive: String?
    var issues: [String] = []
    var verifiedNoDomains = false
    var ready: Bool { attempted && verifiedNoDomains && issues.isEmpty }
}

/// Transfer identifiers are scoped to their owning Connection, just like item
/// identifiers. Views and notifications must retain that namespace too.
struct DriveTransfer: Identifiable {
    let drive: DriveModel
    let entry: TransferEntry
    var id: String { drive.id + ":" + entry.id.uuidString }
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
    private(set) var lastAddedID: String?
    private(set) var preferences = UserPreferences()
    /// The last problem changing a setting, shown in the Settings window.
    private(set) var preferencesError: String?
    private let preferencesStore: PreferencesStore?
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
        preferencesStore = (try? storage.get()).map { PreferencesStore(url: $0.root.appendingPathComponent("preferences.json")) }
        if let preferencesStore {
            do { preferences = try preferencesStore.load() }
            catch { status = "Preferences could not be loaded: \(error.localizedDescription)" }
        }
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
            let disconnected = (try? await backend.disconnectedDomainIDs()) ?? []
            for drive in drives {
                try Task.checkCancellation()
                drive.restorePausedState(disconnected.contains(drive.id))
                // A provider replacement can clear the native disconnection.
                // Reapply the user's durable request before starting monitors.
                do {
                    if drive.isRegistered && !drive.isPaused,
                       let reason = try MountOptions.load(in: store.folder(for: drive.id)).pauseReason {
                        await drive.setPaused(true, byUser: reason == .user)
                    }
                } catch {
                    loadIssues.append(ConnectionLoadIssue(id: "pause-" + drive.id,
                        message: "\(drive.name): saved pause settings could not be read. \(error.localizedDescription)"))
                }
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

    func updatePreference<Value>(_ key: WritableKeyPath<UserPreferences, Value>, _ value: Value) {
        var candidate = preferences
        candidate[keyPath: key] = value
        guard (try? candidate.validated()) != nil else {
            preferencesError = "That value is outside the allowed range, so the setting was not changed."
            return
        }
        do {
            guard let preferencesStore else { throw CocoaError(.fileWriteNoPermission) }
            try preferencesStore.save(candidate)
            preferences = candidate
            preferencesError = nil
        } catch { preferencesError = "Settings couldn't be saved: \(error.localizedDescription)" }
    }

    /// Settings problems are shown in the Settings window, next to the change.
    func reportSettings(_ message: String) { preferencesError = message }
    func clearSettingsMessage() { preferencesError = nil }

    func report(_ message: String) { status = message }

    func maintainCaches() async {
        guard !busy else { return }
        let usage = cacheUsage
        guard usage.measuredAt != nil else { return }
        var excess = max(0, usage.total - Int64(preferences.maximumCacheGB * 1e9))
        if preferences.freeOnLowDisk && usage.free < 2_000_000_000 {
            excess = max(excess, 2_000_000_000 - usage.free)
        }
        guard excess > 0 || preferences.cacheAgeDays > 0 else { return }
        for drive in drives where drive.isRegistered && !drive.isPaused && !drive.busy {
            do {
                let freed = try await DomainManagement(settings: drive.settings).maintainCache(bytes: excess,
                    ageDays: preferences.cacheAgeDays)
                excess = max(0, excess - freed)
            } catch { EventLog.record("cache_maintenance_failed", error: error) }
        }
    }

    func importProfiles(_ settings: [ConnectionSettings]) throws {
        try importProfiles(settings.map { ConnectionProfiles.Imported(settings: $0, options: nil) })
    }

    func importProfiles(_ profiles: [ConnectionProfiles.Imported]) throws {
        guard !busy, !preparingUninstall else { throw CocoaError(.fileLocking) }
        let store = try storage.get()
        // Validate the complete document before writing any records.
        for profile in profiles {
            try ConnectionStore.validate(profile.settings)
            _ = try profile.options?.validated()
        }
        var count = 0
        for profile in profiles {
            let item = profile.settings
            if drives.contains(where: { $0.settings.hasSameEndpoint(as: item) }) { continue }
            guard try store.existingSettings(for: item.id) == nil else { throw ConnectionStoreError.endpointChanged }
            try store.importProfile(profile)
            drives.append(DriveModel(settings: item, isRegistered: false, store: store,
                                      backend: backend, monitor: makeMonitor()))
            count += 1
        }
        status = "Imported \(count) mounts. Reconnect each mount to sign in."
    }

    func add(_ settings: ConnectionSettings, password: String, keepDownloaded: Bool? = nil) async -> Bool {
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
            if Task.isCancelled, drives.contains(where: { $0 === drive }) {
                let cleanup = Task { @MainActor in await drive.removeConnection() }
                if let result = await cleanup.value { finishRemoval(drive, result: result) }
                else { status = "Connection cancelled. \(drive.name) was retained because cleanup needs attention: \(drive.status)" }
                return false
            }
            status = connected ? "Added \(drive.name)." : drive.status
            if !connected { addFailure = drive.connectFailure }
            if connected {
                lastAddedID = drive.id
                if keepDownloaded ?? preferences.keepNewMounts { await drive.keepAll() }
                if preferences.openAfterMount { await drive.openFinder() }
            }
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
        case .clearCache: await drive.clearCache()
        case .keepAll: await drive.keepAll()
        case .pause: await drive.setPaused(true)
        case .resume: await drive.setPaused(false)
        case .rebuild: await drive.rebuild()
        }
    }

    var allPaused: Bool { !drives.filter(\.isRegistered).isEmpty && drives.filter(\.isRegistered).allSatisfy(\.isPaused) }

    func setAllPaused(_ paused: Bool) async {
        guard !busy else { return }
        for drive in drives { await drive.setPaused(paused) }
    }

    func refreshSnapshots(forceCache: Bool = false) async {
        guard !preparingUninstall else { return }
        for drive in drives {
            if Task.isCancelled { return }
            await drive.readSnapshot(forceCache: forceCache)
        }
    }

    var cacheUsage: CacheUsage {
        var usage = CacheUsage()
        for snapshot in drives.compactMap(\.snapshot) {
            usage.cached = NonnegativeTotals.add(usage.cached, snapshot.cache.cached)
            usage.keptOffline = NonnegativeTotals.add(usage.keptOffline, snapshot.cache.keptOffline)
            usage.onlineOnlyCount = NonnegativeTotals.add(usage.onlineOnlyCount, snapshot.cache.onlineOnlyCount)
            usage.offlineSelectionCount = NonnegativeTotals.add(usage.offlineSelectionCount, snapshot.cache.offlineSelectionCount)
            if let error = snapshot.cache.measurementError { usage.measurementError = error }
            usage.free = max(usage.free, snapshot.cache.free)
            usage.measuredAt = [usage.measuredAt, snapshot.cache.measuredAt].compactMap { $0 }.min()
        }
        return usage
    }

    var transfers: [DriveTransfer] {
        drives.flatMap { drive in (drive.snapshot?.transfers ?? []).map { DriveTransfer(drive: drive, entry: $0) } }
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
