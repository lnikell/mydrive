import SwiftUI

@MainActor struct MountInfoSheet: View {
    let drive: DriveModel
    let reconnect: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = MountOptions()
    @State private var exclusions = ""
    @State private var failure = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                DriveBadge(kind: drive.kind, size: 40, style: .solid)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name).font(Typography.title3).foregroundStyle(Palette.primary)
                    Text(drive.address).font(Typography.mono).foregroundStyle(Palette.secondary)
                }
            }
            FormGroup(title: "Connection") {
                FormRow(label: "Path", separator: false) { ReadOnlyValue(value: drive.share) }
                FormRow(label: "Account") { ReadOnlyValue(value: drive.username) }
                FormRow(label: "Password", detail: "Stored in Keychain") {
                    Button("Reconnect…") { reconnect(); dismiss() }.buttonStyle(CardButtonStyle())
                }
                FormRow(label: "Files") {
                    MenuButton(entries: {
                        [.item("Online-only", checked: drive.snapshot?.rootKeptOffline != true,
                               action: { Task { await drive.setMountOffline(false) } }),
                         .item("Keep downloaded", checked: drive.snapshot?.rootKeptOffline == true,
                               action: { Task { await drive.setMountOffline(true) } })]
                    }) { _ in Text(drive.snapshot?.rootKeptOffline == true ? "Keep downloaded" : "Online-only").modifier(PopupChrome()) }
                        .buttonStyle(.plain).disabled(!drive.isRegistered || drive.isPaused || drive.busy)
                }
            }
            FormGroup(title: "Bandwidth") {
                FormRow(label: "Override", separator: false) { Toggle("Use mount limits", isOn: $options.overrideBandwidth).toggleStyle(.switch) }
                FormRow(label: "Download") { limit(value: $options.downloadMBps, enabled: $options.downloadLimited) }
                FormRow(label: "Upload") { limit(value: $options.uploadMBps, enabled: $options.uploadLimited) }
            }
            FormGroup(title: "Never sync", footnote: "One name or relative path per line. Global exclusions also apply.") {
                FormRow(label: "Rules", separator: false) { TextEditor(text: $exclusions).font(Typography.mono).frame(height: 80) }
            }
            if !failure.isEmpty { FormError(message: failure) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(CardButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    options.excludedPatterns = exclusions.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    do {
                        options.pauseReason = try MountOptions.load(for: drive.id).pauseReason
                        try options.save(for: drive.id)
                        Task {
                            do {
                                if drive.isRegistered && !drive.isPaused { try await DomainManagement(settings: drive.settings).policyChanged() }
                                dismiss()
                            } catch { failure = "Options were saved. Finder could not resume previously excluded files: \(error.localizedDescription)" }
                        }
                    }
                    catch { failure = error.localizedDescription }
                }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560).background(Palette.window)
        .task {
            do { options = try MountOptions.load(for: drive.id); exclusions = options.excludedPatterns.joined(separator: "\n") }
            catch { failure = error.localizedDescription }
        }
    }

    private func limit(value: Binding<Double>, enabled: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            TextField("", value: value, format: .number).frame(width: 70)
            Text("MB/s").foregroundStyle(Palette.secondary)
            Toggle("Enabled", isOn: enabled).labelsHidden().toggleStyle(.switch)
        }.disabled(!options.overrideBandwidth)
    }
}
