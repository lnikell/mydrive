import Foundation
import Observation

/// One saved connection owns its status, work and monitor. The settings snapshot
/// cannot be reassigned while an operation is suspended in a framework call.
@MainActor @Observable final class DriveModel: Identifiable {
    nonisolated let settings: ConnectionSettings
    private(set) var busy = false
    private(set) var status = ""
    private(set) var connectionStatus = ""
    /// The latest automatic-refresh state, for status indicators.
    private(set) var monitorState: ConnectionMonitor.State?
    /// When known folders were last checked successfully in this session.
    private(set) var lastChecked: Date?
    /// 1 finds the server, 2 signs in, 3 adds the drive to Finder;
    /// 0 means no connection is running.
    private(set) var connectStep = 0
    /// Why the last connection attempt failed, so a form can point at the cause.
    private(set) var connectFailure: (any Error)?
    private(set) var isRegistered: Bool
    private(set) var isPaused = false
    private(set) var pauseReason: MountOptions.PauseReason?
    private(set) var snapshot: ProviderSnapshot?
    private(set) var snapshotError = ""
    private var sampling = false
    private var lastSnapshotAttempt = Date.distantPast
    private let store: ConnectionStore
    private let backend: any DriveConnectionBackend
    private let monitor: ConnectionMonitor
    private var monitoringEnabled = true

    nonisolated var id: String { settings.domainID }
    var name: String { settings.displayName }
    var host: String { settings.host }
    var share: String { settings.share }
    var username: String { settings.username }

    init(settings: ConnectionSettings, isRegistered: Bool, store: ConnectionStore,
         backend: any DriveConnectionBackend, monitor: ConnectionMonitor = ConnectionMonitor()) {
        self.settings = settings
        self.isRegistered = isRegistered
        self.store = store
        self.backend = backend
        self.monitor = monitor
        if !isRegistered { connectionStatus = "Not registered in Finder. Reconnect to finish adding this drive." }
    }

    func reconnect(password: String) async -> Bool {
        guard !busy else { return false }
        busy = true
        monitoringEnabled = true
        connectFailure = nil
        defer { busy = false; connectStep = 0 }
        await monitor.stop()
        do {
            status = "Finding server…"
            connectStep = 1
            try await backend.verifyReachability(settings)
            try Task.checkCancellation()
            connectStep = 2
            status = "Signing in…"
            try await backend.verify(settings, password: password)
            try Task.checkCancellation()
            // Keep the record if registration/refresh fails. Startup can offer
            // the same ID again without abandoning a partially accepted domain.
            try store.save(settings)
            status = "Connecting in Finder…"
            connectStep = 3
            try await backend.activate(settings, password: password)
            try Task.checkCancellation()
            isRegistered = true
            isPaused = false
            pauseReason = nil
            let folder = try store.folder(for: id)
            var options = try MountOptions.load(in: folder)
            options.pauseReason = nil
            try options.save(in: folder)
            status = "Connected."
            await startMonitoring()
            return true
        } catch {
            connectFailure = error
            if let registered = try? await backend.registeredDomainIDs() {
                isRegistered = registered.contains(id)
            }
            status = error is CancellationError ? "Connection cancelled." : error.localizedDescription
            if isRegistered { await startMonitoring() }
            else { connectionStatus = "Reconnect to finish adding this drive." }
            return false
        }
    }

    func refresh() async { await perform(.refresh) }
    func openFinder() async { await perform(.openFinder) }
    func keepSelected() async { await perform(.keepSelected) }
    func offloadSelected() async { await perform(.offloadSelected) }
    func offloadAll() async { await perform(.offloadAll) }
    func clearCache() async { await perform(.clearCache) }
    func keepAll() async { await perform(.keepAll) }
    func rebuild() async { await perform(.rebuild) }

    func readSnapshot(forceCache: Bool = false) async {
        guard isRegistered, !isPaused, !sampling else { return }
        guard forceCache || snapshotError.isEmpty || Date().timeIntervalSince(lastSnapshotAttempt) >= 15 else { return }
        sampling = true
        lastSnapshotAttempt = Date()
        defer { sampling = false }
        do {
            snapshot = try await backend.snapshot(settings, measureCache: forceCache ||
                Date().timeIntervalSince(snapshot?.cache.measuredAt ?? .distantPast) > 60)
            snapshotError = ""
        } catch is CancellationError { }
        catch { snapshotError = error.localizedDescription }
    }

    func library(scope: LibraryScope, afterID: String?, generation: Int64?) async throws -> LibraryPage {
        try await backend.library(settings, scope: scope, afterID: afterID, generation: generation)
    }

    func perform(_ action: LibraryAction, itemID: String) async throws {
        guard !busy else { throw CocoaError(.fileLocking) }
        try await backend.perform(action, itemID: itemID, settings: settings)
        await readSnapshot(forceCache: true)
    }

    func setPaused(_ paused: Bool, byUser: Bool = true) async {
        guard isRegistered, !busy, paused != isPaused else { return }
        busy = true
        defer { busy = false }
        await monitor.stop()
        do {
            status = try await backend.perform(paused ? .pause : .resume, settings: settings)
            isPaused = paused
            pauseReason = paused ? (byUser ? .user : .automatic) : nil
            let folder = try store.folder(for: id)
            var options = try MountOptions.load(in: folder)
            options.pauseReason = pauseReason
            try options.save(in: folder)
            if paused, var snapshot {
                snapshot = ProviderSnapshot(cache: snapshot.cache, transfers: snapshot.transfers.map { entry in
                    var item = entry
                    if item.active { item.state = .queued; item.bytesPerSecond = 0; item.message = "Paused" }
                    return item
                }, connection: snapshot.connection, rootKeptOffline: snapshot.rootKeptOffline, today: snapshot.today)
                self.snapshot = snapshot
            }
        } catch { status = error.localizedDescription }
        if !isPaused { await startMonitoring() }
    }

    func restorePausedState(_ paused: Bool) {
        isPaused = paused
        if paused { pauseReason = (try? MountOptions.load(in: store.folder(for: id)).pauseReason) ?? .user }
    }
    func setVisible(_ visible: Bool) async throws { try await backend.setVisible(visible, settings: settings) }
    func setMountOffline(_ keep: Bool) async {
        do { try await DomainManagement(settings: settings).setMountOffline(keep); await readSnapshot(forceCache: true) }
        catch { status = error.localizedDescription }
    }

    func startMonitoring() async {
        guard isRegistered, monitoringEnabled, !isPaused else { return }
        let settings = self.settings, backend = self.backend, monitor = self.monitor
        // A cancelled sheet operation must restore the drive's monitor too.
        // This awaited owner does not inherit cancellation from that caller.
        let owner = Task { @MainActor [weak self] in
            guard self?.monitoringEnabled == true else { return }
            let interval = (try? PreferencesStore.shared().load().retrySeconds) ?? 30
            await monitor.start(interval: interval, refresh: {
                _ = try await backend.perform(.refresh, settings: settings)
            }, onState: { [weak self] state in self?.monitorChanged(state) })
        }
        await owner.value
    }

    func stopMonitoring() async {
        monitoringEnabled = false
        await monitor.stop()
    }

    private func monitorChanged(_ state: ConnectionMonitor.State) {
        monitorState = state
        if state == .refreshed { lastChecked = Date() }
        switch state {
        case .waiting:
            let interval = (try? PreferencesStore.shared().load().retrySeconds) ?? 30
            connectionStatus = "Checking for changes every \(interval) seconds while MyDrive runs."
        case .refreshing: connectionStatus = "Checking for changes…"
        case .refreshed: connectionStatus = "Changes checked."
        case let .retrying(seconds, message): connectionStatus = "Retrying in \(seconds) seconds. \(message)"
        case let .paused(message): connectionStatus = "Automatic refresh paused. \(message)"
        }
    }

    func removeConnection() async -> ConnectionRemoval? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        await monitor.stop()
        do {
            status = "Disconnecting…"
            let result = try await backend.remove(settings, store: store)
            isRegistered = false
            connectionStatus = "Disconnected."
            return result
        } catch {
            status = error is CancellationError ? "Disconnection cancelled." : error.localizedDescription
            if isRegistered { await startMonitoring() }
            return nil
        }
    }

    private func perform(_ action: DriveAction) async {
        guard !busy else { return }
        guard isRegistered || action == .rebuild else { status = "Reconnect this drive first."; return }
        busy = true
        defer { busy = false }
        await monitor.stop()
        do {
            status = try await backend.perform(action, settings: settings)
            if action == .rebuild {
                isRegistered = try await backend.registeredDomainIDs().contains(id)
                restorePausedState(try await backend.disconnectedDomainIDs().contains(id))
            }
            if action == .refresh { lastChecked = Date() }
        }
        catch { status = error is CancellationError ? "Operation cancelled." : error.localizedDescription }
        if isRegistered { await startMonitoring() }
    }
}
