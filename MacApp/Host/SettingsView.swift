import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

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
            GeneralSettings(updates: updates, model: model)
                .tabItem { Label { Text("General") } icon: { Image(nsImage: IconLibrary.image(.settings)) } }
                .tag(SettingsTab.general)
            SyncSettings(model: model)
                .tabItem { Label { Text("Sync & Cache") } icon: { Image(nsImage: IconLibrary.image(.cloud)) } }
                .tag(SettingsTab.syncCache)
            NetworkSettings(model: model)
                .tabItem { Label { Text("Network") } icon: { Image(nsImage: IconLibrary.image(.globe)) } }
                .tag(SettingsTab.network)
            AdvancedSettings(model: model, requestRemoveAll: requestRemoveAll)
                .tabItem { Label { Text("Advanced") } icon: { Image(nsImage: IconLibrary.image(.terminal)) } }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 640)
        .overlay(alignment: .bottom) {
            if let message = model.preferencesError {
                SettingsProblem(message: message, dismiss: model.clearSettingsMessage)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.preferencesError)
    }
}

/// A settings change that could not be applied, shown where it happened.
private struct SettingsProblem: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Icon(.warning, size: 14).foregroundStyle(Palette.red).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(message).font(Typography.callout).foregroundStyle(Palette.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("OK", action: dismiss).buttonStyle(CardButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.redSoft, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
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
    var reason = unavailable
    var body: some View {
        LabeledContent {
            Picker(title, selection: .constant(value)) { Text(value).tag(value) }
                .labelsHidden()
                .fixedSize()
                .disabled(true)
        } label: {
            RowLabel(title: title, detail: detail)
        }
        .help(reason)
    }
}

private struct SettingsFooter: View {
    let text: String
    var body: some View { Text(text).font(Typography.subheadline).foregroundStyle(Palette.tertiary) }
}

extension AppModel {
    func preference<Value>(_ key: WritableKeyPath<UserPreferences, Value>) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: key] }, set: { self.updatePreference(key, $0) })
    }
}

@MainActor private struct PreferenceToggle: View {
    let model: AppModel
    let title: String
    var detail: String?
    let key: WritableKeyPath<UserPreferences, Bool>
    var body: some View { Toggle(isOn: model.preference(key)) { RowLabel(title: title, detail: detail) }.accessibilityLabel(title) }
}

// MARK: - General

@MainActor private struct GeneralSettings: View {
    @Bindable var updates: UpdateController
    @Bindable var model: AppModel
    @State private var loginEnabled = false
    @State private var serviceError = ""

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
                Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: { value in setLogin(value) }))
                PreferenceToggle(model: model, title: "Show in menu bar", detail: "Quick access to mounts, transfers and pause", key: \.showMenuBar)
                PreferenceToggle(model: model, title: "Show icon in Dock", key: \.showDock)
            } footer: {
                SettingsFooter(text: "MyDrive keeps running when its window is closed.")
            }
            Section("Finder") {
                PreferenceToggle(model: model, title: "Show mounts in Finder sidebar", key: \.showFinder)
                PreferenceToggle(model: model, title: "Open in Finder after mounting", key: \.openAfterMount)
                PreferenceToggle(model: model, title: "Reconnect after sleep or network change", key: \.reconnectOnChange)
            }
            Section {
                PreferenceToggle(model: model, title: "Sync conflicts", key: \.notifyConflicts)
                PreferenceToggle(model: model, title: "Connection lost or restored", key: \.notifyConnections)
                PreferenceToggle(model: model, title: "Large transfer finished", detail: "Files over 100 MB", key: \.notifyTransfers)
            } header: {
                Text("Notifications")
            } footer: {
                SettingsFooter(text: "macOS may ask you to allow MyDrive notifications.")
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
        .onAppear { loginEnabled = SMAppService.mainApp.status == .enabled }
        .alert("Launch at Login", isPresented: Binding(get: { !serviceError.isEmpty }, set: { if !$0 { serviceError = "" } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(serviceError) }
    }

    private func setLogin(_ enabled: Bool) {
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                loginEnabled = SMAppService.mainApp.status == .enabled
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch { serviceError = error.localizedDescription }
        }
    }
}

// MARK: - Sync & Cache

@MainActor private struct SyncSettings: View {
    @Bindable var model: AppModel
    @State private var confirmingClear = false
    @State private var clearing = false
    @State private var editingExclusions = false
    @State private var exclusions = ""

    private var registered: [DriveModel] { model.drives.filter(\.isRegistered) }

    var body: some View {
        Form {
            Section("New mounts") {
                LabeledContent {
                    Picker("Files are", selection: model.preference(\.keepNewMounts)) {
                        Text("Online-only").tag(false)
                        Text("Keep downloaded").tag(true)
                    }.labelsHidden().fixedSize()
                } label: { RowLabel(title: "Files are", detail: "Online-only files download the first time you open them") }
                FixedChoice(title: "When a file changes in two places", value: "Keep both copies",
                            reason: "Both versions are preserved as separate files. This is MyDrive's conflict policy.")
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(cacheText(model.cacheUsage.total)).font(.title.bold()).foregroundStyle(Palette.primary)
                        Text("used").font(Typography.body).foregroundStyle(Palette.secondary)
                        Spacer()
                        Text(model.cacheUsage.measurementError == nil ? model.cacheUsage.measuredAt.map { "Measured \(RelativeTime.short($0).lowercased())" } ?? "Measuring…" : "Measurement needs attention")
                            .font(Typography.callout).foregroundStyle(Palette.tertiary)
                            .help(model.cacheUsage.measurementError ?? "Local allocated download size")
                    }
                    ProgressBar(value: Double(model.cacheUsage.total) / Double(max(1, Int64(model.preferences.maximumCacheGB * 1e9))), height: 6)
                    HStack(spacing: 16) {
                        legend(Palette.accent, "Cache " + cacheText(model.cacheUsage.cached))
                        legend(Palette.purple, "Kept offline " + cacheText(model.cacheUsage.keptOffline))
                        legend(Palette.track, "Free " + cacheText(model.cacheUsage.free))
                    }
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Maximum cache size") { Text("\(Int(model.preferences.maximumCacheGB)) GB").font(Typography.bodyMedium) }
                    HStack(spacing: 10) {
                        Text("5 GB").font(Typography.subheadline).foregroundStyle(Palette.tertiary)
                        Slider(value: model.preference(\.maximumCacheGB), in: 5...100, step: 1)
                        Text("100 GB").font(Typography.subheadline).foregroundStyle(Palette.tertiary)
                    }
                }
                PreferenceToggle(model: model, title: "Free up space when the disk is almost full", key: \.freeOnLowDisk)
                LabeledContent("Remove cached files not opened for") {
                    Picker("Remove cached files not opened for", selection: model.preference(\.cacheAgeDays)) {
                        Text("Never").tag(0)
                        ForEach([1, 7, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
                    }.labelsHidden().fixedSize()
                }
                LabeledContent {
                    Button(clearing ? "Clearing…" : "Clear Cache…") { confirmingClear = true }
                        .disabled(clearing || model.busy || registered.isEmpty || registered.contains(where: \.busy))
                } label: {
                    RowLabel(title: "Cached files", detail: "Kept-offline files are never removed")
                }
            } header: {
                Text("Local cache")
            } footer: {
                SettingsFooter(text: "Cache maintenance frees clean local downloads. Kept-offline files, pending edits and server originals are kept.")
            }
            Section {
                HStack {
                    Text(model.preferences.excludedPatterns.isEmpty ? "No exclusions" : "\(model.preferences.excludedPatterns.count) rules")
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("Edit…") { exclusions = model.preferences.excludedPatterns.joined(separator: "\n"); editingExclusions = true }
                }
            } header: {
                Text("Never sync")
            } footer: {
                SettingsFooter(text: "Excluded names and paths stay on their server or this Mac. Wildcards * and ? are supported.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(height: 740)
        .sheet(isPresented: $editingExclusions) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Never sync").font(Typography.title3)
                Text("One name or relative path per line. Use * and ? as wildcards.").foregroundStyle(Palette.secondary)
                TextEditor(text: $exclusions).font(Typography.mono).frame(height: 180)
                HStack {
                    Spacer()
                    Button("Cancel") { editingExclusions = false }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        model.updatePreference(\.excludedPatterns, exclusions.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                        editingExclusions = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 480)
        }
        .confirmationDialog("Clear the local cache?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Free Up Space on All Mounts", role: .destructive, action: clearCache)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded copies are removed from this Mac. Files on your servers, kept-offline files and pending edits are kept.")
        }
    }

    private func cacheText(_ bytes: Int64) -> String {
        model.cacheUsage.measuredAt == nil ? "—" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
            for drive in drives where !drive.busy { await model.perform(.clearCache, on: drive) }
            clearing = false
        }
    }
}

// MARK: - Network

@MainActor private struct NetworkSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                speedRow("Limit download speed", value: \.downloadMBps, enabled: \.downloadLimited)
                speedRow("Limit upload speed", value: \.uploadMBps, enabled: \.uploadLimited)
                LabeledContent {
                    Picker("Apply limits", selection: model.preference(\.limitSchedule)) {
                        ForEach(["Always", "Work hours (9–18)", "Outside work hours"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().fixedSize()
                } label: { RowLabel(title: "Apply limits", detail: "Outside these hours transfers run at full speed") }
            } header: {
                Text("Bandwidth")
            } footer: {
                SettingsFooter(text: "Limits apply to transfers started while the selected schedule is active.")
            }
            Section("Pause syncing") {
                PreferenceToggle(model: model, title: "On Low Data Mode or a personal hotspot", key: \.pauseOnConstrained)
                PreferenceToggle(model: model, title: "On battery below 20 %", key: \.pauseOnLowBattery)
            }
            Section {
                LabeledContent("Simultaneous transfers") {
                    HStack(spacing: 0) {
                        Button("−") { model.updatePreference(\.simultaneousTransfers, model.preferences.simultaneousTransfers - 1) }
                            .frame(width: 26).disabled(model.preferences.simultaneousTransfers <= 1)
                        Text("\(model.preferences.simultaneousTransfers)").font(Typography.bodyMedium).foregroundStyle(Palette.primary).frame(width: 30)
                            .overlay(alignment: .leading) { Rectangle().fill(Palette.separator).frame(width: 1) }
                            .overlay(alignment: .trailing) { Rectangle().fill(Palette.separator).frame(width: 1) }
                        Button("+") { model.updatePreference(\.simultaneousTransfers, model.preferences.simultaneousTransfers + 1) }
                            .frame(width: 26).disabled(model.preferences.simultaneousTransfers >= 8)
                    }
                    .foregroundStyle(Palette.secondary)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.control))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.separator, lineWidth: 1))
                    .buttonStyle(.plain)
                }
                LabeledContent("Retry when a server is unreachable") {
                    Picker("Retry interval", selection: model.preference(\.retrySeconds)) {
                        ForEach([15, 30, 60, 300], id: \.self) { Text("Every \($0) seconds, then less often").tag($0) }
                    }.labelsHidden().fixedSize()
                }
            } header: {
                Text("Transfers")
            } footer: {
                SettingsFooter(text: "Retries back off when a server remains unreachable.")
            }
            Section {
                Toggle(isOn: model.preference(\.discoverTailnet)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Discover peers on my tailnet")
                        HStack(spacing: 6) {
                            StatusDot(color: model.preferences.discoverTailnet ? Palette.green : Palette.tertiary)
                            Text(DiscoveryService.shared.status)
                                .font(Typography.subheadline).foregroundStyle(Palette.secondary)
                        }
                    }
                }
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

    private func speedRow(_ title: String, value: WritableKeyPath<UserPreferences, Double>, enabled: WritableKeyPath<UserPreferences, Bool>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                BandwidthField(title: title, value: model.preference(value), report: model.reportSettings)
                Text("MB/s").font(Typography.callout).foregroundStyle(Palette.secondary)
                Toggle("", isOn: model.preference(enabled)).labelsHidden().accessibilityLabel(title + " enabled")
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// Editing a fractional value passes through empty/zero text. Persist only the
/// finished value, so normal localized typing never reports a storage failure.
@MainActor private struct BandwidthField: View {
    let title: String
    @Binding var value: Double
    let report: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(title: String, value: Binding<Double>, report: @escaping (String) -> Void) {
        self.title = title; self._value = value; self.report = report
        self._draft = State(initialValue: value.wrappedValue.formatted(.number.precision(.fractionLength(0...1))))
    }

    var body: some View {
        TextField("", text: $draft)
            .frame(width: 56).multilineTextAlignment(.trailing).accessibilityLabel(title)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, active in if !active { commit() } }
            .onChange(of: value) { _, updated in
                if !focused { draft = updated.formatted(.number.precision(.fractionLength(0...1))) }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        if let number = try? Double(draft, format: .number), number.isFinite, (0.1...10000).contains(number) {
            if number != value { value = number }
        } else {
            report("Enter a speed between 0.1 and 10,000 MB/s.")
        }
        draft = value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

// MARK: - Advanced

@MainActor private struct AdvancedSettings: View {
    @Bindable var model: AppModel
    let requestRemoveAll: () -> Void
    @State private var failure = ""
    @State private var confirmingRebuild = false

    var body: some View {
        Form {
            Section {
                buttonRow("Export profiles", detail: "Servers, paths and options. Passwords are not included.", button: "Export…", action: exportProfiles)
                buttonRow("Import profiles", button: "Import…") { importProfiles(mountainDuck: false) }
                buttonRow("Import from Mountain Duck", detail: "SMB bookmarks; sign in again after importing", button: "Import…") { importProfiles(mountainDuck: true) }
            } header: {
                Text("Connection profiles")
            } footer: {
                SettingsFooter(text: "Imported mounts keep their own local identity. Passwords are requested when you reconnect.")
            }
            Section("Credentials") {
                buttonRow("Passwords and keys", detail: "Stored in the keychain", button: "Open Keychain Access") {
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") else {
                        failure = "Keychain Access could not be found on this Mac."; return
                    }
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
                FixedChoice(title: "Default SSH key", value: "None")
            }
            Section("Troubleshooting") {
                PreferenceToggle(model: model, title: "Verbose logging", key: \.verboseLogging)
                buttonRow("Logs", button: "Show in Finder") {
                    do { NSWorkspace.shared.activateFileViewerSelecting([try EventLog.directory()]) }
                    catch { failure = error.localizedDescription }
                }
                buttonRow("Rebuild Finder integration", detail: "Re-registers every mount with macOS. Cached files stay.",
                          button: "Rebuild…") { confirmingRebuild = true }
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
        .alert("Settings", isPresented: Binding(get: { !failure.isEmpty }, set: { if !$0 { failure = "" } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure) }
        .confirmationDialog("Rebuild Finder integration?", isPresented: $confirmingRebuild, titleVisibility: .visible) {
            Button("Rebuild") {
                Task {
                    for drive in model.drives where !drive.busy { await model.perform(.rebuild, on: drive) }
                }
            }
        } message: { Text("Each mount is registered again using its existing identity. Local files and server originals are kept.") }
    }

    private func buttonRow(_ title: String, detail: String? = nil, button: String, action: @escaping () -> Void) -> some View {
        LabeledContent {
            Button(button, action: action).disabled(model.busy)
        } label: {
            RowLabel(title: title, detail: detail)
        }
    }

    private func exportProfiles() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MyDrive Profiles.json"
        panel.allowedContentTypes = [.json]
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let options = try Dictionary(uniqueKeysWithValues: model.drives.map { ($0.id, try MountOptions.load(for: $0.id)) })
                try encoder.encode(ConnectionProfiles(settings: model.drives.map(\.settings), options: options)).write(to: url, options: .atomic)
            } catch { failure = error.localizedDescription }
        }
    }

    private func importProfiles(mountainDuck: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = mountainDuck
        panel.allowedContentTypes = mountainDuck ? [UTType(filenameExtension: "duck") ?? .data] : [.json]
        Task {
            guard await panel.begin() == .OK else { return }
            do {
                var settings: [ConnectionProfiles.Imported] = []
                for url in panel.urls {
                    let bytes = try BoundedFile.read(url, maximumBytes: 1_048_576)
                    settings += try mountainDuck ? [.init(settings: ConnectionProfiles.mountainDuck(bytes), options: nil)] : ConnectionProfiles.read(bytes)
                }
                try model.importProfiles(settings)
            } catch { failure = error.localizedDescription }
        }
    }
}
