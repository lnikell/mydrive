import AppKit
import SwiftUI

struct ConnectionSheetRequest: Identifiable {
    let id = UUID()
    let settings: ConnectionSettings
    let drive: DriveModel?
}

/// Requests from menus and the Settings window that the main window presents.
@MainActor @Observable final class WindowRequests {
    var add = false
    var connectToURL = false
    var removal: RemovalMode?
}

@MainActor struct MainWindow: View {
    @Bindable var model: AppModel
    @Bindable var requests: WindowRequests
    @Environment(\.openSettings) private var openSettings
    @SwiftUI.AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general
    @State private var log = ActivityLog()
    @State private var selection = SidebarItem.allMounts
    @State private var query = ""
    @State private var sheet: ConnectionSheetRequest?
    @State private var removingDrive: DriveModel?
    @State private var showingLoadIssues = false
    @State private var showingRetainedWork = false
    @State private var showingConnectURL = false
    @State private var removal: RemovalMode?
    @State private var quitRequested = false
    @State private var inspecting: DriveModel?
    @State private var reconnectAfterInfo: DriveModel?

    var body: some View {
        presentations(lifecycle(layout))
    }

    private var layout: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection, drives: model.drives, activityBadge: activityBadge, cache: model.cacheUsage, cacheLimitGB: model.preferences.maximumCacheGB,
                    openCacheSettings: { settingsTab = .syncCache; openSettings() },
                    openSettings: { openSettings() })
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if selection != .activity {
                    StatusStrip(model: model, log: log, openActivity: { selection = .activity })
                }
            }
            .background(Palette.window)
        }
        .ignoresSafeArea()
        .background(Palette.window)
        .background(WindowChrome())
        .frame(minWidth: 1080, minHeight: 560)
    }

    private func lifecycle(_ view: some View) -> some View {
        view
            .task {
                await model.startup()
                presentRequestedAdd()
                presentRequestedConnectURL()
                presentRequestedRemoval()
            }
            .onChange(of: snapshots, initial: true) { _, value in log.observe(value) }
            .onChange(of: model.status, initial: true) { _, value in log.observeApp(status: value, busy: model.busy) }
            .onChange(of: model.drives.map(\.kind)) { _, kinds in
                if case let .kind(kind) = selection, !kinds.contains(kind) { selection = .allMounts }
            }
            .onChange(of: requests.add) { _, _ in presentRequestedAdd() }
            .onChange(of: model.lastAddedID) { _, id in if id != nil { selection = .allMounts; query = "" } }
            .onChange(of: requests.connectToURL) { _, _ in presentRequestedConnectURL() }
            .onChange(of: requests.removal) { _, _ in presentRequestedRemoval() }
            .onChange(of: model.busy) { _, busy in
                log.observeApp(status: model.status, busy: busy)
                if !busy { presentRequestedAdd(); presentRequestedConnectURL(); presentRequestedRemoval() }
            }
            .onChange(of: showingLoadIssues) { _, showing in if !showing { presentRequestedRemoval() } }
            .onChange(of: removingDrive?.id) { _, id in if id == nil { presentRequestedRemoval() } }
    }

    private func presentations(_ view: some View) -> some View {
        dialogs(view
            .sheet(item: $inspecting, onDismiss: {
                if let drive = reconnectAfterInfo {
                    reconnectAfterInfo = nil
                    sheet = ConnectionSheetRequest(settings: drive.settings, drive: drive)
                } else { presentRequestedRemoval() }
            }) { drive in
                MountInfoSheet(drive: drive) { reconnectAfterInfo = drive }
            }
            .sheet(item: $sheet, onDismiss: presentRequestedRemoval) { request in
                DriveConnectionSheet(model: model, settings: request.settings, drive: request.drive)
            }
            .sheet(isPresented: $showingConnectURL, onDismiss: presentRequestedRemoval) {
                ConnectURLSheet(proceed: continueFromURL, draft: model.makeDraft)
            }
            .sheet(isPresented: $showingRetainedWork, onDismiss: presentRequestedRemoval) {
                RetainedWorkView(locations: model.retainedWork)
            }
            .sheet(item: $removal, onDismiss: removalDismissed) { mode in
                UninstallView(model: model, mode: mode, requestQuit: requestUninstallQuit)
            })
    }

    private func dialogs(_ view: some View) -> some View {
        view
            .confirmationDialog(
                "Disconnect \(removingDrive?.name ?? "this drive") and remove local downloads?",
                isPresented: Binding(get: { removingDrive != nil }, set: { if !$0 { removingDrive = nil } }),
                titleVisibility: .visible
            ) {
                if let drive = removingDrive {
                    Button("Disconnect & Remove Local Downloads", role: .destructive) {
                        Task { await model.remove(drive) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Files on the NAS are kept. Clean local downloads are removed. Pending edits and upload recovery data are preserved, with an option to show them in Finder.")
            }
            .alert("Saved Mount Issues", isPresented: $showingLoadIssues) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.loadIssues.map(\.message).joined(separator: "\n\n"))
            }
    }

    private func continueFromURL(_ settings: ConnectionSettings) {
        showingConnectURL = false
        // Present the add sheet after this one has finished dismissing.
        DispatchQueue.main.async { sheet = ConnectionSheetRequest(settings: settings, drive: nil) }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .allMounts:
            MountsPane(model: model, kind: nil, actions: actions, query: $query)
        case let .kind(kind):
            MountsPane(model: model, kind: kind, actions: actions, query: $query)
        case .activity:
            ActivityPane(model: model, log: log, actions: actions,
                         showRetainedWork: { showingRetainedWork = true }, showLoadIssues: { showingLoadIssues = true })
        case .onlineOnly:
            LibraryPane(model: model, scope: .onlineOnly).id(LibraryScope.onlineOnly)
        case .keptOffline:
            LibraryPane(model: model, scope: .keptOffline).id(LibraryScope.keptOffline)
        case .discovered:
            DiscoveredPane(mount: presentAdd)
        }
    }

    private var actions: MountActions {
        MountActions(
            addSMB: presentAdd,
            connectToURL: presentConnectURL,
            reconnect: { drive in
                guard !model.busy, removal == nil else { return }
                sheet = ConnectionSheetRequest(settings: drive.settings, drive: drive)
            },
            disconnect: { drive in removingDrive = drive },
            perform: { action, drive in Task { await model.perform(action, on: drive) } },
            refreshAll: {
                Task {
                    for drive in model.drives where drive.isRegistered && !drive.busy {
                        await model.perform(.refresh, on: drive)
                    }
                }
            }, info: { drive in inspecting = drive })
    }

    private var snapshots: [ActivityLog.Snapshot] {
        model.drives.map { ActivityLog.Snapshot(id: $0.id, name: $0.name, status: $0.status, busy: $0.busy) }
    }

    private var activityBadge: Int {
        model.drives.filter { $0.busy || $0.health.needsAttention }.count
            + (model.loadIssues.isEmpty ? 0 : 1) + (model.retainedWork.isEmpty ? 0 : 1)
    }

    private var canPresent: Bool {
        !model.busy && removal == nil && sheet == nil && removingDrive == nil && !showingConnectURL && inspecting == nil
    }

    private func presentAdd() {
        guard canPresent else { return }
        var draft = model.makeDraft()
        if let address = DiscoveryService.shared.pendingAddress {
            draft.host = address
            DiscoveryService.shared.pendingAddress = nil
        }
        sheet = ConnectionSheetRequest(settings: draft, drive: nil)
    }

    private func presentConnectURL() {
        guard canPresent else { return }
        showingConnectURL = true
    }

    private func presentRequestedAdd() {
        guard requests.add, !model.busy else { return }
        requests.add = false
        presentAdd()
    }

    private func presentRequestedConnectURL() {
        guard requests.connectToURL, !model.busy else { return }
        requests.connectToURL = false
        presentConnectURL()
    }

    private func presentRequestedRemoval() {
        guard let mode = requests.removal, !model.busy, sheet == nil, removingDrive == nil,
              !showingRetainedWork, !showingLoadIssues, !showingConnectURL, inspecting == nil, removal == nil else { return }
        requests.removal = nil
        removal = mode
    }

    private func requestUninstallQuit() {
        guard model.uninstall.ready, !model.busy else { return }
        quitRequested = true
    }

    private func removalDismissed() {
        guard quitRequested else {
            presentRequestedRemoval()
            return
        }
        quitRequested = false
        guard model.uninstall.ready, !model.busy else { return }
        // Terminating while a sheet is still attached can cancel termination.
        // SwiftUI's dismissal callback is the lifecycle barrier for this action.
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApplication.shared.terminate(nil)
    }
}

@MainActor private struct RetainedWorkView: View {
    let locations: [URL]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(icon: .folder, size: 40, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unsynced Changes").font(Typography.title3).foregroundStyle(Palette.primary)
                    Text("Saved on this Mac when a mount was disconnected").font(Typography.callout).foregroundStyle(Palette.secondary)
                }
            }
            Text("These files had changes that weren't uploaded yet. Copy anything you still need back to the server before deleting them.")
                .font(Typography.body).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(locations, id: \.self) { location in
                        HStack(spacing: 10) {
                            Text(location.path).font(Typography.mono).foregroundStyle(Palette.primary)
                                .textSelection(.enabled).lineLimit(2)
                            Spacer(minLength: 8)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
                                .buttonStyle(CardButtonStyle())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                }
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.subtle))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.separator, lineWidth: 1))
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Palette.window)
    }
}
