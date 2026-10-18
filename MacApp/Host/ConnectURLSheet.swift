import SwiftUI

/// "Connect to URL…": accepts a pasted address and continues in the Add sheet
/// with the server and share filled in. Only smb:// is supported today.
@MainActor struct ConnectURLSheet: View {
    let proceed: (ConnectionSettings) -> Void
    let draft: () -> ConnectionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var failure = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(icon: .globe, size: 40, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect to URL").font(Typography.title3).foregroundStyle(Palette.primary)
                    Text("Paste a server address to mount it").font(Typography.callout).foregroundStyle(Palette.secondary)
                }
            }
            TextField("Address", text: $address, prompt: Text("smb://nas.local/Shared"))
                .textFieldStyle(.roundedBorder)
                .font(Typography.mono.weight(.regular))
                .autocorrectionDisabled()
                .onSubmit(submit)
            Text("SMB addresses work today. SFTP, WebDAV and S3 addresses aren't supported yet.")
                .font(Typography.subheadline).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !failure.isEmpty {
                Text(failure).font(Typography.callout).foregroundStyle(Palette.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 12))
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: submit)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Palette.window)
    }

    private func submit() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if let scheme = input.range(of: "://").map({ input[..<$0.lowerBound].lowercased() }), scheme != "smb" {
            failure = "\(scheme):// addresses aren't supported yet. MyDrive can mount SMB shares today."
            return
        }
        var settings = draft()
        do {
            let parsed = try SMBAddress(server: input, share: "")
            settings.host = input
            settings.share = parsed.share
        } catch SMBAddressError.shareRequired {
            // A server without a share continues with the Share field empty.
            settings.host = input
            settings.share = ""
        } catch {
            failure = error.localizedDescription
            return
        }
        proceed(settings)
    }
}
