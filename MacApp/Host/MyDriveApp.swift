import AppKit
import SwiftUI

@main struct MyDriveApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var model = AppModel()
    @State private var updates = UpdateController()
    @State private var addRequested = false
    @State private var uninstallRequested = false

    var body: some Scene {
        Window("MyDrive", id: "connection") {
            ConnectionsView(model: model, addRequested: $addRequested, uninstallRequested: $uninstallRequested)
                .frame(minWidth: 480, idealWidth: 560, minHeight: 320, idealHeight: 400)
        }
        .defaultSize(width: 560, height: 400)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates || model.preparingUninstall)
                Divider()
                Button("Uninstall MyDrive…", action: requestUninstall)
                    .disabled(model.busy || model.drives.contains(where: \.busy))
            }
            CommandGroup(after: .newItem) {
                Button("Add Drive…", action: requestAdd)
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.busy)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit MyDrive") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .disabled(model.preparingUninstall)
            }
        }
        Settings { UpdateSettingsView(updates: updates) }
        MenuBarExtra("MyDrive", systemImage: "externaldrive.badge.wifi") {
            Button("Show Drives") { openWindow(id: "connection") }
            Button("Add Drive…", action: requestAdd).disabled(model.busy)
            if !model.drives.isEmpty {
                Divider()
                ForEach(model.drives) { drive in
                    Button("Open \(drive.name) in Finder") { Task { await model.perform(.openFinder, on: drive) } }
                        .disabled(drive.busy || model.busy)
                }
            }
            Divider()
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates || model.preparingUninstall)
            Button("Uninstall MyDrive…", action: requestUninstall)
                .disabled(model.busy || model.drives.contains(where: \.busy))
            Button("Quit MyDrive") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .disabled(model.preparingUninstall)
        }
    }

    private func requestAdd() {
        guard !model.busy else { return }
        openWindow(id: "connection")
        addRequested = true
    }

    private func requestUninstall() {
        guard !model.busy else { return }
        openWindow(id: "connection")
        uninstallRequested = true
    }
}
