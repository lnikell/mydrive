import SwiftUI

@MainActor struct DriveConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State var settings: ConnectionSettings
    let drive: DriveModel?
    @State private var password = ""
    @State private var submitting = false
    @State private var failure = ""
    @State private var submission: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                DriveBadge(kind: .smb, size: 40, style: .solid)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isAdding ? "Add SMB Share" : "Reconnect \(settings.displayName)")
                        .font(Typography.title3).foregroundStyle(Palette.primary)
                    Text(isAdding ? "Mount a NAS share in Finder" : "Enter the password to resume syncing")
                        .font(Typography.callout).foregroundStyle(Palette.secondary)
                }
            }
            Form {
                if isAdding {
                    TextField("Name (optional)", text: $settings.displayName, prompt: Text("Uses the share name"))
                    TextField("Server", text: $settings.host, prompt: Text("nas.local or smb://nas.local/Shared"))
                        .autocorrectionDisabled()
                    TextField("Share", text: $settings.share, prompt: Text("Shared folder name"))
                        .autocorrectionDisabled()
                    TextField("Username", text: $settings.username).autocorrectionDisabled()
                } else {
                    LabeledContent("Server", value: settings.host)
                    LabeledContent("Share", value: settings.share)
                    LabeledContent("Username", value: settings.username)
                }
                SecureField("Password", text: $password)
                    .onSubmit { if canSubmit { submit() } }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 240)
            .disabled(submitting)
            Text("Use your NAS file-sharing account. MyDrive verifies the connection before adding it to Finder.")
                .font(Typography.subheadline).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if AppStorage.isDevelopmentStorage {
                Text("This development build connects only to the configured test NAS. Credentials expire after 15 minutes.")
                    .font(Typography.subheadline).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !failure.isEmpty {
                Text(failure).font(Typography.callout).foregroundStyle(Palette.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if submitting {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(Typography.callout).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
                    .keyboardShortcut(.cancelAction).disabled(submitting)
                Button(isAdding ? "Add Mount" : "Reconnect", action: submit)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Palette.window)
        .interactiveDismissDisabled(submitting)
        .onDisappear {
            submission?.cancel()
            submission = nil
            password = ""
        }
    }

    private var canSubmit: Bool {
        !submitting && !model.busy && !password.isEmpty && [settings.host, settings.username]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isAdding: Bool {
        drive == nil && !model.drives.contains { $0.id == settings.domainID }
    }

    private func submit() {
        guard canSubmit else { return }
        failure = ""
        let secret = password
        var candidate = settings
        do {
            if isAdding {
                let address = try SMBAddress(server: candidate.host, share: candidate.share)
                candidate.host = address.endpoint
                candidate.share = address.share
            }
        } catch {
            failure = error.localizedDescription
            return
        }
        if candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidate.displayName = candidate.share
        }
        settings = candidate
        submitting = true
        submission = Task {
            let success: Bool
            if let drive { success = await model.reconnect(drive, password: secret) }
            else { success = await model.add(candidate, password: secret) }
            submitting = false
            guard !Task.isCancelled else { return }
            if success {
                password = ""
                dismiss()
            } else {
                failure = drive?.status ?? model.status
            }
        }
    }
}
