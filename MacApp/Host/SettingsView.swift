import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, syncCache, network, advanced
    static let storageKey = "settingsTab"
}

/// Native tabbed Settings window (⌘,). Rows marked "Not available yet" show the
/// app's current fixed behaviour until those features are implemented.
@MainActor struct SettingsView: View {
    @Bindable var updates: UpdateController
    @Bindable var model: AppModel
    let requestRemoveAll: () -> Void
    @SwiftUI.AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(updates: updates)
                .tabItem { Label { Text("General") } icon: { Image(nsImage: IconLibrary.image(.settings)) } }
                .tag(SettingsTab.general)
            SyncSettings(model: model)
                .tabItem { Label { Text("Sync & Cache") } icon: { Image(nsImage: IconLibrary.image(.cloud)) } }
                .tag(SettingsTab.syncCache)
            NetworkSettings()
                .tabItem { Label { Text("Network") } icon: { Image(nsImage: IconLibrary.image(.globe)) } }
                .tag(SettingsTab.network)
            AdvancedSettings(requestRemoveAll: requestRemoveAll)
                .tabItem { Label { Text("Advanced") } icon: { Image(nsImage: IconLibrary.image(.terminal)) } }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 640)
    }
}

private let unavailable = "Not available yet."

/// A two-line row label: title with a secondary description.
private struct RowLabel: View {
    let title: String
    var detail: String?
    var tint: Color?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(tint ?? Palette.primary)
            if let detail { Text(detail).font(Typography.subheadline).foregroundStyle(Palette.secondary) }
        }
    }
}

/// A disabled switch that reflects behaviour the app does not let you change yet.
private struct FixedToggle: View {
    let title: String
    var detail: String?
    let value: Bool
    var body: some View {
        Toggle(isOn: .constant(value)) { RowLabel(title: title, detail: detail) }
            .disabled(true)
            .help(unavailable)
    }
}

/// A disabled pop-up showing the current fixed choice.
private struct FixedChoice: View {
    let title: String
    var detail: String?
    let value: String
    var body: some View {
        LabeledContent {
            Picker(title, selection: .constant(value)) { Text(value).tag(value) }
                .labelsHidden()
                .fixedSize()
                .disabled(true)
        } label: {
            RowLabel(title: title, detail: detail)
        }
        .help(unavailable)
    }
}

private struct SettingsFooter: View {
    let text: String
    var body: some View { Text(text).font(Typography.subheadline).foregroundStyle(Palette.tertiary) }
}

// MARK: - General

@MainActor private struct GeneralSettings: View {
    @Bindable var updates: UpdateController

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    private var lastChecked: String {
        guard updates.isAvailable else { return "Updates are available in a configured release build." }
        guard let date = updates.lastUpdateCheckDate else { return "Not checked yet" }
        let day = Calendar.current.isDateInToday(date) ? "today" : date.formatted(date: .abbreviated, time: .omitted)
        return "Last checked \(day) at \(RelativeTime.clock(date))"
    }

    var body: some View {
        Form {
            Section {
                FixedToggle(title: "Launch at login", value: false)
                FixedToggle(title: "Show in menu bar", detail: "Quick access to mounts, transfers and pause", value: true)
                FixedToggle(title: "Show icon in Dock", value: true)
            } footer: {
                SettingsFooter(text: "These options aren't available yet. MyDrive opens from the Dock and the menu bar.")
            }
            Section("Finder") {
                FixedToggle(title: "Show mounts in Finder sidebar", value: true)
                FixedToggle(title: "Open in Finder after mounting", value: false)
                FixedToggle(title: "Reconnect after sleep or network change", value: false)
            }
            Section {
                FixedToggle(title: "Sync conflicts", value: false)
                FixedToggle(title: "Connection lost or restored", value: false)
                FixedToggle(title: "Large transfer finished", detail: "Files over 100 MB", value: false)
            } header: {
                Text("Notifications")
            } footer: {
                SettingsFooter(text: "Notifications aren't available yet.")
            }
            Section("Updates") {
                Toggle(isOn: $updates.automaticallyChecksForUpdates) { RowLabel(title: "Check for updates automatically") }
                    .disabled(!updates.isAvailable)
                Toggle(isOn: $updates.automaticallyDownloadsUpdates) { RowLabel(title: "Download and install updates automatically") }
                    .disabled(!updates.isAvailable || !updates.allowsAutomaticUpdates)
                LabeledContent {
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                } label: {
                    RowLabel(title: version, detail: lastChecked)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(height: 780)
    }
}

// MARK: - Sync & Cache

@MainActor private struct SyncSettings: View {
    @Bindable var model: AppModel
    @State private var confirmingClear = false
    @State private var clearing = false

    private var registered: [DriveModel] { model.drives.filter(\.isRegistered) }

    var body: some View {
        Form {
            Section("New mounts") {
                FixedChoice(title: "Files are", detail: "Online-only files download the first time you open them",
                            value: "Online-only")
                FixedChoice(title: "When a file changes in two places", value: "Keep both copies")
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("—").font(.title.bold()).foregroundStyle(Palette.primary)
                        Text("used").font(Typography.body).foregroundStyle(Palette.secondary)
                        Spacer()
                        Text("Usage isn't measured yet").font(Typography.callout).foregroundStyle(Palette.tertiary)
                    }
                    ProgressBar(value: 0, height: 6)
                    HStack(spacing: 16) {
                        legend(Palette.accent, "Cache —")
                        legend(Palette.purple, "Kept offline —")
                        legend(Palette.track, "Free —")
                    }
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Maximum cache size") { Text("—").font(Typography.bodyMedium) }
                    HStack(spacing: 10) {
                        Text("5 GB").font(Typography.subheadline).foregroundStyle(Palette.tertiary)
                        Slider(value: .constant(0.16)).disabled(true)
                        Text("100 GB").font(Typography.subheadline).foregroundStyle(Palette.tertiary)
                    }
                }
                .help(unavailable)
                FixedToggle(title: "Free up space when the disk is almost full", value: false)
                FixedChoice(title: "Remove cached files not opened for", value: "Never")
                LabeledContent {
                    Button(clearing ? "Clearing…" : "Clear Cache…") { confirmingClear = true }
                        .disabled(clearing || model.busy || registered.isEmpty || registered.contains(where: \.busy))
                } label: {
                    RowLabel(title: "Cached files", detail: "Kept-offline files are never removed")
                }
            } header: {
                Text("Local cache")
            } footer: {
                SettingsFooter(text: "Clear Cache frees local downloads on every mount, like Free Up Space. Cache limits aren't available yet.")
            }
            Section {
                HStack {
                    Text("No exclusions").foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("Edit…") {}.disabled(true)
                }
                .help(unavailable)
            } header: {
                Text("Never sync")
            } footer: {
                SettingsFooter(text: "Exclusion rules aren't available yet.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(height: 740)
        .confirmationDialog("Clear the local cache?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Free Up Space on All Mounts", role: .destructive, action: clearCache)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded copies are removed from this Mac. Files on your servers, kept-offline files and pending edits are kept.")
        }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).font(Typography.subheadline).foregroundStyle(Palette.secondary)
        }
    }

    private func clearCache() {
        let drives = registered
        clearing = true
        Task {
            for drive in drives where !drive.busy { await model.perform(.offloadAll, on: drive) }
            clearing = false
        }
    }
}

// MARK: - Network

private struct NetworkSettings: View {
    var body: some View {
        Form {
            Section {
                speedRow("Limit download speed")
                speedRow("Limit upload speed")
                FixedChoice(title: "Apply limits", detail: "Outside these hours transfers run at full speed", value: "Always")
            } header: {
                Text("Bandwidth")
            } footer: {
                SettingsFooter(text: "Bandwidth limits aren't available yet.")
            }
            Section("Pause syncing") {
                FixedToggle(title: "On Low Data Mode or a personal hotspot", value: false)
                FixedToggle(title: "On battery below 20 %", value: false)
            }
            Section {
                LabeledContent("Simultaneous transfers") {
                    HStack(spacing: 0) {
                        Text("−").frame(width: 26)
                        Text("4").font(Typography.bodyMedium).foregroundStyle(Palette.primary).frame(width: 30)
                            .overlay(alignment: .leading) { Rectangle().fill(Palette.separator).frame(width: 1) }
                            .overlay(alignment: .trailing) { Rectangle().fill(Palette.separator).frame(width: 1) }
                        Text("+").frame(width: 26)
                    }
                    .foregroundStyle(Palette.secondary)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.control))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.separator, lineWidth: 1))
                    .opacity(0.6)
                }
                .help("Folder imports run up to four transfers at once. " + unavailable)
                FixedChoice(title: "Retry when a server is unreachable", value: "Every 30 seconds, then less often")
            } header: {
                Text("Transfers")
            } footer: {
                SettingsFooter(text: "These values are fixed for now.")
            }
            Section {
                Toggle(isOn: .constant(false)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Discover peers on my tailnet")
                        HStack(spacing: 6) {
                            StatusDot(color: Palette.tertiary)
                            Text("Tailscale discovery isn't available yet")
                                .font(Typography.subheadline).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                .disabled(true)
                LabeledContent("Look for") {
                    HStack(spacing: 6) {
                        ForEach([MountKind.smb, .sftp, .webDAV]) { kind in
                            Text(kind.title)
                                .font(Typography.calloutMedium)
                                .foregroundStyle(Palette.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(Capsule().fill(Palette.control))
                        }
                    }
                    .opacity(0.6)
                }
                .help(unavailable)
            } header: {
                Text("Tailscale")
            } footer: {
                SettingsFooter(text: "Peers will appear in the sidebar under Discovered and in the Add menu.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(height: 700)
    }

    private func speedRow(_ title: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", text: .constant(""), prompt: Text("—")).frame(width: 56).multilineTextAlignment(.trailing)
                Text("MB/s").font(Typography.callout).foregroundStyle(Palette.secondary)
                Toggle("", isOn: .constant(false)).labelsHidden()
            }
            .disabled(true)
        }
        .help(unavailable)
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    let requestRemoveAll: () -> Void

    var body: some View {
        Form {
            Section {
                disabledButtonRow("Export profiles", detail: "Servers, paths and options. Passwords are not included.", button: "Export…")
                disabledButtonRow("Import profiles", button: "Import…")
                disabledButtonRow("Import from Mountain Duck", detail: "Bookmarks and credentials from your keychain", button: "Import…")
            } header: {
                Text("Connection profiles")
            } footer: {
                SettingsFooter(text: "Profile import and export aren't available yet.")
            }
            Section("Credentials") {
                disabledButtonRow("Passwords and keys", detail: "Stored in the keychain", button: "Open Keychain Access")
                FixedChoice(title: "Default SSH key", value: "None")
            }
            Section("Troubleshooting") {
                FixedToggle(title: "Verbose logging", value: false)
                disabledButtonRow("Logs", button: "Show in Finder")
                disabledButtonRow("Rebuild Finder integration", detail: "Re-registers every mount with macOS. Cached files stay.",
                                  button: "Rebuild…")
            }
            Section {
                LabeledContent {
                    Button("Remove All…", role: .destructive, action: requestRemoveAll)
                        .foregroundStyle(Palette.red)
                } label: {
                    RowLabel(title: "Remove all mounts", detail: "Disconnects every server and removes local downloads",
                             tint: Palette.red)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .toggleStyle(.switch)
        .frame(height: 660)
    }

    private func disabledButtonRow(_ title: String, detail: String? = nil, button: String) -> some View {
        LabeledContent {
            Button(button) {}.disabled(true)
        } label: {
            RowLabel(title: title, detail: detail)
        }
        .help(unavailable)
    }
}
