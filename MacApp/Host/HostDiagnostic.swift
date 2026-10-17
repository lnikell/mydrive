import Darwin
import FileProvider
import Foundation

struct HostDiagnosticRequest {
    enum Action: String {
        case registration, connection, credential, refresh, pin, offload, remove
        case connectionReset = "connection-reset", offloadAll = "offload-all"
        #if MYDRIVE_DEVELOPMENT
        case session
        case localNetwork = "local-network"
        #endif
    }
    let action: Action
    let identifier: String?
    let domainID: String
    var reportMode: String {
        switch action {
        case .registration: "registration"
        case .connection, .connectionReset: "connection"
        case .credential: "credential"
        #if MYDRIVE_DEVELOPMENT
        case .session: "session"
        case .localNetwork: "local-network"
        #endif
        default: "control"
        }
    }

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, first.hasPrefix("--probe-"),
              let action = Action(rawValue: String(first.dropFirst(8))) else {
            throw probeError(1, "Unknown diagnostic mode.")
        }
        var values = arguments
        var domainID = "unas-test"
        #if MYDRIVE_DEVELOPMENT
        if values.count >= 3, values[values.count - 2] == "--domain" {
            domainID = values.removeLast()
            values.removeLast()
            guard ConnectionSettings.validDomainID(domainID) else { throw probeError(1, "Use a canonical drive identifier.") }
        }
        #endif
        let needsID = action == .pin || action == .offload
        guard values.count == (needsID ? 2 : 1) else { throw probeError(1, "Invalid diagnostic argument count.") }
        self.action = action
        self.domainID = domainID
        if needsID {
            let value = values[1]
            if value == "root" || value == NSFileProviderItemIdentifier.rootContainer.rawValue {
                identifier = NSFileProviderItemIdentifier.rootContainer.rawValue
            } else {
                let hex = value.utf8.count == 32 && value.utf8.allSatisfy {
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }
                let uuid = value.count == 36 && UUID(uuidString: value)?.uuidString.caseInsensitiveCompare(value) == .orderedSame
                guard hex || uuid else { throw probeError(7, "Use a catalog UUID or the root item identifier; paths are not accepted.") }
                identifier = value
            }
        } else { identifier = nil }
    }
}

@MainActor enum HostDiagnostic {
    static func run(_ arguments: [String]) async {
        let parsed = try? HostDiagnosticRequest(arguments)
        guard let root = try? AppStorage.rootURL(),
              let report = try? ProbeReport(mode: parsed?.reportMode ?? "control", root: root,
                                           operation: parsed?.action.rawValue, identifier: parsed?.identifier,
                                           domainID: parsed?.domainID) else {
            FileHandle.standardError.write(Data("Diagnostic output is unavailable.\n".utf8))
            return
        }
        let watchdog = DispatchWorkItem { @Sendable in if report.timeout() { Darwin._exit(124) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: watchdog)
        defer { watchdog.cancel() }
        var password: String?
        do {
            let request = try HostDiagnosticRequest(arguments)
            #if MYDRIVE_DEVELOPMENT
            let expected = try DevelopmentConnectionScope.settings(domainID: request.domainID)
            #else
            guard let expected = try AppStorage.existingSettings(for: request.domainID) else {
                throw probeError(2, "Diagnostics require an existing saved connection.")
            }
            #endif
            try report.stage("validating_endpoint")
            let saved = try AppStorage.existingSettings(for: expected.domainID)
            if let saved, !saved.hasSameEndpoint(as: expected) {
                throw probeError(2, "The saved connection targets a different endpoint. Remove it before using this diagnostic.")
            }
            let settings = saved ?? expected
            #if MYDRIVE_DEVELOPMENT
            try DevelopmentConnectionScope.validate(settings)
            if request.domainID != "unas-test", saved == nil {
                throw probeError(2, "Explicit drive diagnostics require an existing matching saved connection.")
            }
            #endif
            if request.reportMode == "control", saved == nil {
                throw probeError(2, "Control diagnostics require the existing matching test connection.")
            }
            #if MYDRIVE_DEVELOPMENT
            if request.action == .session, saved == nil {
                throw probeError(2, "A development session requires the existing matching test connection.")
            }
            #endif
            let management = DomainManagement(settings: settings)
            switch request.action {
            #if MYDRIVE_DEVELOPMENT
            case .localNetwork:
                try await LocalNetworkProbe.requestAccess(for: settings, report: report)
                try report.stage("complete", terminal: true)
            case .session:
                guard AppStorage.isDevelopmentStorage else { throw probeError(8, "Development sessions are unavailable.") }
                try report.stage("reading_password")
                let entered = try await Task.detached(priority: .utility) { try readPassword() }.value
                password = entered
                try report.stage("probing_smb")
                try await SMBClient(settings: settings).probe(password: entered)
                try report.stage("saving_settings")
                try AppStorage.save(settings)
                try report.stage("registering_domain")
                try await management.registerIfNeeded()
                try report.stage("installing_development_credential", registration: "accepted")
                try await management.useDevelopmentCredential(entered)
                try report.stage("restoring_connection")
                try await management.connectionRestored()
                try report.stage("looking_up_root")
                let url = try await management.rootURL()
                try report.stage("complete", finderRoot: url.path, terminal: true)
                password = nil
            #endif
            case .refresh:
                try report.stage("refreshing")
                try await management.refresh()
                try report.completeControl(message: "Refreshed known folders.")
            case .pin:
                try report.stage("requesting_offline")
                try await management.keepDownloaded([request.identifier!])
                try report.completeControl(message: "Requested offline availability; download completion is verified separately.")
            case .offload:
                try report.stage("offloading")
                try report.completeControl(message: await management.offload([request.identifier!]))
            case .offloadAll:
                try report.stage("offloading_all")
                try report.completeControl(message: await management.offload())
            case .remove:
                try report.stage("removing_domain")
                let result = try await management.remove()
                try report.completeControl(message: "File Provider confirmed test-domain removal.",
                    preservedURL: result.preservedURL, cleanupFailures: result.cleanupFailures)
            case .credential:
                try report.stage("reading_credential")
                _ = try CredentialStore.password(for: settings, allowInteraction: false)
                try report.stage("complete", credentialRead: "allowed", terminal: true)
            case .registration, .connection, .connectionReset:
                if request.action != .registration {
                    try report.stage("reading_password")
                    let entered = try await Task.detached(priority: .utility) { try readPassword() }.value
                    password = entered
                    try report.stage("probing_smb")
                    try await SMBClient(settings: settings).probe(password: entered)
                    #if !MYDRIVE_DEVELOPMENT
                    if request.action == .connectionReset {
                        try report.stage("resetting_credentials")
                        try CredentialStore.remove(for: settings)
                    }
                    try report.stage("saving_credentials")
                    try CredentialStore.save(entered, for: settings, allowInteraction: false)
                    password = nil
                    #endif
                }
                try report.stage("saving_settings")
                try AppStorage.save(settings)
                try report.stage("registering_domain")
                try await management.register()
                if request.action != .registration {
                    try report.stage("restoring_connection", registration: "accepted")
                    #if MYDRIVE_DEVELOPMENT
                    guard let enteredPassword = password else { throw SMBClientError.authenticationRequired }
                    try await management.useDevelopmentCredential(enteredPassword)
                    #endif
                    try await management.connectionRestored()
                    password = nil
                }
                try report.stage("looking_up_root", registration: "accepted")
                let url = try await management.rootURL()
                try report.stage("complete", finderRoot: url.path, terminal: true)
            }
        } catch { report.fail(error, redacting: password) }
    }

    nonisolated private static func readPassword() throws -> String {
        var info = stat()
        guard isatty(STDIN_FILENO) == 0, fstat(STDIN_FILENO, &info) == 0,
              info.st_mode & S_IFMT == S_IFIFO else { throw probeError(3, "Password input must be a pipe terminated by EOF.") }
        let input = FileHandle.standardInput
        defer { try? input.close() }
        var bytes = Data()
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        while let chunk = try input.read(upToCount: 4097 - bytes.count), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= 4096 else { throw probeError(4, "Password input exceeds 4096 bytes.") }
        }
        guard !bytes.isEmpty, let password = String(data: bytes, encoding: .utf8) else {
            throw probeError(5, "Password input must contain nonempty UTF-8 bytes.")
        }
        return password
    }
}

func probeError(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "MyDriveDiagnostic", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}
