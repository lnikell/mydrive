import SwiftUI

@MainActor struct UpdateSettingsView: View {
    @Bindable var updates: UpdateController

    var body: some View {
        Form {
            Section("Software Updates") {
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                    .disabled(!updates.isAvailable)
                Toggle("Download and install updates automatically", isOn: $updates.automaticallyDownloadsUpdates)
                    .disabled(!updates.isAvailable || !updates.allowsAutomaticUpdates)
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                if !updates.isAvailable {
                    Text("Updates are available in a configured release build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 420)
    }
}
