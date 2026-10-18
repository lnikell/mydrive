import AppKit
import SwiftUI

@main struct MyDriveApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var model = AppModel()
    @State private var updates = UpdateController()
    @State private var requests = WindowRequests()
    @State private var runtime = ApplicationRuntime()

    var body: some Scene {
        Window("MyDrive", id: "connection") {
            MainWindow(model: model, requests: requests)
                .task { await model.startup(); await runtime.run(model) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates || model.preparingUninstall)
                Divider()
                Button("Uninstall MyDrive…") { requestRemoval(.uninstall) }
                    .disabled(model.busy || model.drives.contains(where: \.busy))
            }
            CommandGroup(after: .newItem) {
                Button("Add SMB Share…", action: requestAdd)
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.busy)
                Button("Connect to URL…", action: requestConnectURL)
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.busy)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit MyDrive") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .disabled(model.preparingUninstall)
            }
        }
        Settings {
            SettingsView(updates: updates, model: model) { requestRemoval(.removeAll) }
        }
        MenuBarExtra("MyDrive", systemImage: "externaldrive.badge.wifi", isInserted: model.preference(\.showMenuBar)) {
            Button("Show Mounts") { openWindow(id: "connection") }
            Button("Add SMB Share…", action: requestAdd).disabled(model.busy)
            Button("Connect to URL…", action: requestConnectURL).disabled(model.busy)
            if !model.drives.isEmpty {
                Divider()
                ForEach(model.drives) { drive in
                    Button("Open \(drive.name) in Finder") { Task { await model.perform(.openFinder, on: drive) } }
                        .disabled(drive.busy || model.busy)
                }
            }
            Divider()
            Button(model.allPaused ? "Resume Syncing" : "Pause Syncing") { Task { await model.setAllPaused(!model.allPaused) } }
                .disabled(model.busy || model.drives.isEmpty)
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates || model.preparingUninstall)
            Button("Uninstall MyDrive…") { requestRemoval(.uninstall) }
                .disabled(model.busy || model.drives.contains(where: \.busy))
            Button("Quit MyDrive") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .disabled(model.preparingUninstall)
        }
    }

    private func requestAdd() {
        guard !model.busy else { return }
        openWindow(id: "connection")
        requests.add = true
    }

    private func requestConnectURL() {
        guard !model.busy else { return }
        openWindow(id: "connection")
        requests.connectToURL = true
    }

    private func requestRemoval(_ mode: RemovalMode) {
        guard !model.busy else { return }
        openWindow(id: "connection")
        requests.removal = mode
    }
}
