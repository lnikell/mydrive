import AppKit
import FileProvider
import Foundation
import IOKit.ps
import Network
import UserNotifications

/// Host lifecycle and user policy only. File Provider continues to own all
/// callbacks, uploads, downloads and replica availability.
@MainActor final class ApplicationRuntime {
    private var owner: Task<Void, Never>?
    private var constrained = false
    private var reachable = false
    private var wakeObserver: NSObjectProtocol?
    private var notificationIDs: Set<String> = []
    private var previousConnections: [String: Bool] = [:]
    private var applied: UserPreferences?
    private var lastMaintenance = Date.distantPast
    private let launched = Date()

    func run(_ model: AppModel) async {
        guard owner == nil else { return }
        owner = Task { await self.monitor(model) }
    }

    private func monitor(_ model: AppModel) async {
        let pathMonitor = NWPathMonitor()
        DiscoveryService.shared.start()
        pathMonitor.pathUpdateHandler = { [weak self, weak model] path in
            Task { @MainActor in
                guard let self, let model else { return }
                let restored = !self.reachable && path.status == .satisfied
                self.reachable = path.status == .satisfied
                self.constrained = path.isConstrained || path.isExpensive
                if restored && model.preferences.reconnectOnChange { await self.refreshConnections(model) }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "local.mydrive.network-policy"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self, weak model] _ in
                Task { @MainActor in
                    guard let self, let model, model.preferences.reconnectOnChange else { return }
                    await self.refreshConnections(model)
                }
            }
        defer {
            pathMonitor.cancel()
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        }
        while !Task.isCancelled {
            if !model.busy {
                await applyPreferences(model)
                await applyPausePolicy(model)
                await model.refreshSnapshots()
                await deliverNotifications(model)
                if Date().timeIntervalSince(lastMaintenance) >= 60 {
                    lastMaintenance = Date()
                    if model.preferences.discoverTailnet { DiscoveryService.shared.scanTailnet() }
                    await model.maintainCaches()
                }
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func applyPreferences(_ model: AppModel) async {
        let preferences = model.preferences
        guard applied != preferences else { return }
        let previous = applied
        applied = preferences
        if previous?.discoverTailnet != preferences.discoverTailnet {
            if preferences.discoverTailnet { DiscoveryService.shared.scanTailnet() }
            else { DiscoveryService.shared.stopTailnet() }
        }
        NSApplication.shared.setActivationPolicy(preferences.showDock ? .regular : .accessory)
        if previous?.showFinder != preferences.showFinder {
            for drive in model.drives where drive.isRegistered {
                do { try await drive.setVisible(preferences.showFinder) }
                catch { model.report("Finder visibility could not be updated: \(error.localizedDescription)") }
            }
        }
        if previous?.retrySeconds != preferences.retrySeconds, previous != nil {
            for drive in model.drives where drive.isRegistered && !drive.isPaused && !drive.busy { await drive.startMonitoring() }
        }
        if previous?.excludedPatterns != preferences.excludedPatterns {
            for drive in model.drives where drive.isRegistered && !drive.isPaused {
                do { try await DomainManagement(settings: drive.settings).policyChanged() }
                catch { model.report("Finder could not resume previously excluded files: \(error.localizedDescription)") }
            }
        }
        let notificationsEnabled = preferences.notifyConflicts || preferences.notifyConnections || preferences.notifyTransfers
        let previouslyEnabled = previous.map { $0.notifyConflicts || $0.notifyConnections || $0.notifyTransfers } ?? false
        if notificationsEnabled && !previouslyEnabled {
            do {
                if try await !UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                    model.report("Notifications are disabled in macOS. Enable MyDrive in System Settings → Notifications.")
                }
            } catch { model.report("Notification permission could not be requested: \(error.localizedDescription)") }
        }
        EventLog.record("preferences_applied", verbose: true)
    }

    private func applyPausePolicy(_ model: AppModel) async {
        let preferences = model.preferences
        let pause = preferences.pauseOnConstrained && constrained || preferences.pauseOnLowBattery && lowBattery()
        for drive in model.drives where drive.isRegistered {
            if pause && !drive.isPaused {
                await drive.setPaused(true, byUser: false)
            } else if !pause && drive.isPaused && drive.pauseReason == .automatic {
                await drive.setPaused(false, byUser: false)
            }
        }
    }

    private func refreshConnections(_ model: AppModel) async {
        guard !model.busy else { return }
        for drive in model.drives where drive.isRegistered && !drive.busy && !drive.isPaused { await drive.refresh() }
    }

    private func lowBattery() -> Bool {
        guard let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(information)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(information, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
            return current / maximum < 0.2
        }
        return false
    }

    private func deliverNotifications(_ model: AppModel) async {
        if notificationIDs.count > 1000 { notificationIDs.formIntersection(Set(model.transfers.map(\.id))) }
        for item in model.transfers where !item.entry.active && (item.entry.finished ?? .distantPast) > launched {
            let drive = item.drive, entry = item.entry
            guard notificationIDs.insert(item.id).inserted else { continue }
            if entry.conflict && model.preferences.notifyConflicts {
                await notify("Sync conflict", "\(drive.name): \(entry.name). Both copies were kept.", id: item.id)
            } else if entry.state == .completed && entry.direction != .operation && entry.total > 100_000_000 && model.preferences.notifyTransfers {
                await notify("Transfer finished", "\(entry.name) · \(drive.name)", id: item.id)
            }
        }
        for drive in model.drives where drive.isRegistered && !drive.isPaused {
            let connected = !drive.health.needsAttention
            let previous = previousConnections.updateValue(connected, forKey: drive.id)
            if let previous, previous != connected, model.preferences.notifyConnections {
                await notify(connected ? "Connection restored" : "Connection lost", drive.name, id: UUID().uuidString)
            }
        }
    }

    private func notify(_ title: String, _ message: String, id: String) async {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = message
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
        catch { EventLog.record("notification_failed", error: error) }
    }
}
