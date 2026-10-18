import SwiftUI

/// "New SMB mount" and "Reconnect" sheet (Figma 03.8 / 03.9). Adding asks
/// where the share is, how to sign in and how it appears on this Mac;
/// reconnecting a saved mount only asks for the password again.
@MainActor struct DriveConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    @State var settings: ConnectionSettings
    let drive: DriveModel?
    @State private var password = ""
    @State private var submitting = false
    @State private var submission: Task<Void, Never>?
    @State private var problem: Problem?
    @State private var autoFilledShare: String?
    @State private var signIn = SignIn.registered
    @State private var keepDownloaded = false
    @State private var cancelling = false
    @State private var shares: [SMBShare] = []
    @State private var listingShares = false
    @State private var shareRequest: Task<Void, Never>?
    @State private var shareRevision = UUID()
    @FocusState private var focus: Field?

    enum Field: Hashable { case address, share, username, password, name }
    enum SignIn: Hashable { case registered, guest }

    /// A failure, attached to the field that caused it when that is known.
    struct Problem: Equatable {
        let field: Field?
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 18) {
                serverGroup
                signInGroup
                if isAdding { macGroup }
                if let problem, problem.field == nil { FormError(message: problem.message) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 22)
            .disabled(submitting)
            footer
        }
        .frame(width: 520)
        .background(Palette.window)
        .interactiveDismissDisabled(submitting)
        .onAppear { keepDownloaded = model.preferences.keepNewMounts; DispatchQueue.main.async { focus = initialFocus } }
        // Only the user's own edits clear a problem; a saved endpoint replacing
        // the typed address after a failed attempt must not.
        .onChange(of: settings.host) { _, value in if isAdding { addressChanged(value); clearProblem(.address) } }
        .onChange(of: settings.share) { _, _ in if isAdding { clearProblem(.share) } }
        .onChange(of: settings.username) { _, _ in if isAdding { cancelShareLookup(); clearProblem(.username) } }
        .onChange(of: password) { _, _ in cancelShareLookup(); clearProblem(.password) }
        .onDisappear {
            submission?.cancel()
            shareRequest?.cancel()
            submission = nil
            password = ""
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            DriveBadge(kind: .smb, size: 40, style: .solid)
            VStack(alignment: .leading, spacing: 2) {
                Text(isAdding ? "New SMB mount" : "Reconnect \(settings.displayName)")
                    .font(Typography.title3).foregroundStyle(Palette.primary)
                Text(isAdding ? "Mount a shared folder from a NAS or a Windows PC."
                              : "Sign in again to resume syncing. Files on this Mac are kept.")
                    .font(Typography.callout).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 2)
    }

    private var serverGroup: some View {
        FormGroup(title: "Server",
                  footnote: isAdding ? "Paste an smb:// address and the share fills in. Port 445 is used unless the address includes another one." : nil,
                  error: message(for: [.address, .share])) {
            FormRow(label: "Address", separator: false) {
                if isAdding {
                    TextField("", text: $settings.host)
                        .font(Typography.mono)
                        .placeholder("nas.local or smb://nas.local/share", when: settings.host.isEmpty, font: Typography.mono)
                        .accessibilityLabel("Address")
                        .focused($focus, equals: .address)
                        .modifier(InputChrome(focused: focus == .address, error: problem?.field == .address))
                } else {
                    ReadOnlyValue(value: settings.address, mono: true)
                }
            }
            FormRow(label: "Share") {
                if isAdding {
                    HStack(spacing: 6) {
                        TextField("", text: $settings.share)
                            .font(Typography.body)
                            .placeholder("Share name", when: settings.share.isEmpty)
                            .accessibilityLabel("Share")
                            .focused($focus, equals: .share)
                        MenuButton(entries: {
                            [.header("Shares on this server")] + shares.map { share in
                                .item(share.name, tooltip: share.comment, checked: settings.share == share.name,
                                      action: { settings.share = share.name })
                            } + [.separator, .item(listingShares ? "Finding shares…" : "Find shares…",
                                enabled: !listingShares && !settings.host.isEmpty && !settings.username.isEmpty && !password.isEmpty,
                                tooltip: "Enter your account and password, then find shares on this server.", action: listShares)]
                        }) { _ in Icon(.chevronDown, size: 12).foregroundStyle(Palette.secondary) }
                            .buttonStyle(.plain)
                            .help("Choose a share")
                            .accessibilityLabel("Choose a share")
                    }
                    .modifier(InputChrome(focused: focus == .share, error: problem?.field == .share))
                } else {
                    ReadOnlyValue(value: settings.share)
                }
            }
        }
    }

    private var signInGroup: some View {
        FormGroup(title: "Sign in", footnote: signInFootnote, error: message(for: [.username, .password])) {
            if isAdding {
                SegmentedPicker(selection: $signIn, segments: [
                    .init(value: .registered, title: "Registered user"),
                    .init(value: .guest, title: "Guest", enabled: false, help: "MyDrive requires signed SMB sessions. Guest access cannot provide a signing key; use a registered account.")
                ])
            }
        } rows: {
            FormRow(label: "Username", separator: false) {
                if isAdding {
                    TextField("", text: $settings.username)
                        .font(Typography.body)
                        .placeholder("Username", when: settings.username.isEmpty)
                        .accessibilityLabel("Username")
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .modifier(InputChrome(focused: focus == .username, error: problem?.field == .username))
                } else {
                    ReadOnlyValue(value: settings.username)
                }
            }
            FormRow(label: "Password") {
                SecureField("", text: $password)
                    .font(Typography.body)
                    .placeholder("Required", when: password.isEmpty)
                    .accessibilityLabel("Password")
                    .focused($focus, equals: .password)
                    .onSubmit { if canSubmit { submit() } }
                    .modifier(InputChrome(focused: focus == .password, error: problem?.field == .password))
            }
        }
    }

    private var macGroup: some View {
        FormGroup(title: "On this Mac") {
            FormRow(label: "Name", detail: "Shown in the Finder sidebar", separator: false) {
                TextField("", text: $settings.displayName)
                    .font(Typography.body)
                    .placeholder(namePlaceholder, when: settings.displayName.isEmpty)
                    .accessibilityLabel("Name")
                    .focused($focus, equals: .name)
                    .modifier(InputChrome(focused: focus == .name))
            }
            FormRow(label: "Files", detail: "Online-only files download when you open them") {
                MenuButton(entries: {
                    [.item("Online-only", checked: !keepDownloaded, action: { keepDownloaded = false }),
                     .item("Keep downloaded", checked: keepDownloaded, action: { keepDownloaded = true })]
                }) { _ in
                    Text(keepDownloaded ? "Keep downloaded" : "Online-only").modifier(PopupChrome())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(keepDownloaded ? "Files: Keep downloaded" : "Files: Online-only")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if submitting {
                ProgressBar(value: Double(max(1, connectStep)) / 3 * 0.9, height: 3)
                    .animation(.easeInOut(duration: 0.4), value: connectStep)
            }
            HStack(spacing: 8) {
                if submitting {
                    ProgressView().controlSize(.small)
                    Text(stepMessage).font(Typography.callout).foregroundStyle(Palette.primary).lineLimit(1)
                    Text("Step \(max(connectStep, 1)) of 3").font(Typography.callout).foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 8)
                Button(cancelling ? "Cancelling…" : "Cancel") {
                    if submitting { cancelling = true; submission?.cancel() }
                    else { dismiss() }
                }
                    .buttonStyle(CardButtonStyle(height: 28, horizontalPadding: 14))
                    .keyboardShortcut(.cancelAction)
                    .disabled(cancelling)
                Button(isAdding ? "Mount" : "Reconnect", action: submit)
                    .buttonStyle(AccentButtonStyle(horizontalPadding: 14))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(.leading, 24)
            .padding(.trailing, 20)
            .padding(.top, 13)
            .padding(.bottom, 14)
        }
        .background(Palette.subtle)
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: State

    private var isAdding: Bool {
        drive == nil && !model.drives.contains { $0.id == settings.domainID }
    }

    private var canSubmit: Bool {
        let required = isAdding ? [settings.host, settings.share, settings.username] : [settings.host, settings.username]
        return !submitting && !model.busy && !password.isEmpty
            && required.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var initialFocus: Field {
        guard isAdding else { return .password }
        if settings.host.isEmpty { return .address }
        if settings.share.isEmpty { return .share }
        if settings.username.isEmpty { return .username }
        return .password
    }

    private var namePlaceholder: String {
        let share = settings.share.trimmingCharacters(in: .whitespaces)
        return share.isEmpty ? "Uses the share name" : share
    }

    private var signInFootnote: String {
        if AppStorage.isDevelopmentStorage {
            return "This development build connects only to the configured test NAS. Credentials expire after 15 minutes."
        }
        return "Saved in your Keychain. MyDrive checks the share before it appears in Finder."
    }

    private var serverName: String {
        if let address = try? SMBAddress(server: settings.host, share: settings.share) {
            return address.endpoint.hasSuffix(":445") ? String(address.endpoint.dropLast(4)) : address.endpoint
        }
        return settings.host
    }

    private var connectStep: Int { (drive ?? model.connecting)?.connectStep ?? 0 }

    private var stepMessage: String {
        switch connectStep {
        case 3: "Adding to Finder…"
        case 2: "Signing in to \(serverName)…"
        default: "Finding \(serverName)…"
        }
    }

    private func message(for fields: Set<Field>) -> String? {
        guard let problem, let field = problem.field, fields.contains(field) else { return nil }
        return problem.message
    }

    private func clearProblem(_ field: Field) {
        if problem?.field == field || problem?.field == nil { problem = nil }
    }

    /// Pasting smb://server/share fills in the share. A share filled this way
    /// follows later address edits until the user types their own.
    private func addressChanged(_ value: String) {
        guard isAdding, !submitting else { return }
        cancelShareLookup()
        let embedded = try? SMBAddress(server: value, share: "").share
        let current = settings.share.trimmingCharacters(in: .whitespaces)
        if let embedded {
            if current.isEmpty || current == autoFilledShare {
                settings.share = embedded
                autoFilledShare = embedded
            }
        } else if let autoFilledShare, current == autoFilledShare {
            settings.share = ""
            self.autoFilledShare = nil
        }
    }

    // MARK: Submit

    private func listShares() {
        guard !listingShares else { return }
        var candidate = settings
        do {
            let address = try SMBAddress(server: candidate.host, share: candidate.share.isEmpty ? "IPC$" : candidate.share)
            candidate.host = address.endpoint; candidate.share = address.share
        } catch { problem = Self.problem(for: error, server: serverName, share: settings.share); return }
        listingShares = true
        let revision = UUID()
        shareRevision = revision
        let secret = password
        shareRequest = Task {
            defer { if shareRevision == revision { listingShares = false } }
            do {
                let found = try await SMBClient(settings: candidate).listShares(password: secret)
                guard shareRevision == revision else { return }
                shares = found
                if shares.isEmpty { problem = Problem(field: .share, message: "This server returned no disk shares for this account. You can enter a share name directly.") }
            } catch is CancellationError { }
            catch { if shareRevision == revision { problem = Self.problem(for: error, server: serverName, share: settings.share) } }
        }
    }

    private func cancelShareLookup() {
        shareRevision = UUID(); shareRequest?.cancel(); shareRequest = nil
        listingShares = false; shares = []
    }

    private func submit() {
        guard canSubmit else { return }
        problem = nil
        let secret = password
        var candidate = settings
        do {
            if isAdding {
                let address = try SMBAddress(server: candidate.host, share: candidate.share)
                candidate.host = address.endpoint
                candidate.share = address.share
            }
        } catch {
            problem = Self.problem(for: error, server: serverName, share: settings.share)
            return
        }
        if candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidate.displayName = candidate.share
        }
        let server = serverName
        submitting = true
        submission = Task {
            let success: Bool
            if let drive { success = await model.reconnect(drive, password: secret) }
            else { success = await model.add(candidate, password: secret, keepDownloaded: keepDownloaded) }
            submitting = false
            guard !Task.isCancelled else { password = ""; dismiss(); return }
            // Once the record is saved, later attempts must use the saved endpoint.
            if model.drives.contains(where: { $0.id == candidate.domainID }) { settings = candidate }
            if success {
                password = ""
                dismiss()
            } else {
                let failure = drive?.connectFailure ?? model.addFailure
                let fallback = drive?.status ?? model.status
                problem = failure.map { Self.problem(for: $0, server: server, share: candidate.share) }
                    ?? Problem(field: nil, message: fallback.isEmpty ? "The share could not be mounted." : fallback)
                focus = problem?.field ?? focus
            }
        }
    }

    /// Places a failure next to the field that caused it.
    static func problem(for error: any Error, server: String, share: String) -> Problem {
        switch error {
        case let error as SMBAddressError:
            switch error {
            case .shareRequired, .invalidShare, .shareConflict:
                return Problem(field: .share, message: error.localizedDescription)
            default:
                return Problem(field: .address, message: error.localizedDescription)
            }
        case let error as SMBClientError:
            switch error {
            case .authenticationRequired:
                return Problem(field: .password, message: "\(server) didn’t accept this username and password.")
            case .serverUnreachable:
                return Problem(field: .address, message: "Can’t reach \(server). Check the address and that the server is on.")
            case .itemMissing:
                return Problem(field: .share, message: "\(server) has no share named “\(share)”.")
            case .permissionDenied:
                return Problem(field: .share, message: "This account can’t open “\(share)” on \(server).")
            case .guestUnsupported:
                return Problem(field: .username, message: error.localizedDescription)
            case .serverPolicy:
                return Problem(field: .address, message: error.localizedDescription)
            default:
                return Problem(field: nil, message: error.localizedDescription)
            }
        default:
            return Problem(field: nil, message: error.localizedDescription)
        }
    }
}
