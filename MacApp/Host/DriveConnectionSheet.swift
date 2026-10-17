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
        VStack(alignment: .leading, spacing: 18) {
            Text(isAdding ? "Add Drive" : "Reconnect \(settings.displayName)")
                .font(.title2.weight(.semibold))
            Form {
                if isAdding {
                    TextField("Name (optional)", text: $settings.displayName, prompt: Text("Uses the share name"))
                    TextField("Server", text: $settings.host, prompt: Text("nas.local or 192.168.1.10"))
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
            .frame(height: 240)
            .disabled(submitting)
            Text("Use your NAS file-sharing account. MyDrive verifies the connection before adding it to Finder.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if AppStorage.isDevelopmentStorage {
                Text("This development build connects only to the configured test NAS. Credentials expire after 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !failure.isEmpty {
                Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if submitting {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                Button(isAdding ? "Add Drive" : "Reconnect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(submitting)
        .onDisappear {
            submission?.cancel()
            submission = nil
            password = ""
        }
    }

    private var canSubmit: Bool {
        !submitting && !password.isEmpty && [settings.host, settings.share, settings.username]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isAdding: Bool {
        drive == nil && !model.drives.contains { $0.id == settings.domainID }
    }

    private func submit() {
        guard canSubmit else { return }
        submitting = true
        failure = ""
        let secret = password
        var candidate = settings
        if candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidate.displayName = candidate.share
        }
        settings = candidate
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
