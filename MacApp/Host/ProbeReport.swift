import Foundation

/// Main actor and watchdog share only this bounded, locked report. Stage writes
/// precede blocking work so an external process cap can also diagnose hangs.
final class ProbeReport: @unchecked Sendable {
    private struct Snapshot: Encodable {
        let mode: String
        let bundle: String
        let operation: String?
        let identifier: String?
        let domainID: String?
        #if MYDRIVE_DEVELOPMENT
        var credentialLifetime: String?
        var persistence: Bool?
        var networkEndpoint: String?
        var networkState: String?
        var pathStatus: String?
        var unsatisfiedReason: String?
        var networkErrorDomain: String?
        var networkErrorCode: Int?
        #endif
        var stage = "started"
        var stages: [String] = []
        var registration: String?
        var credential_read: String?
        var finderRoot: String?
        var preservedURL: String?
        var cleanupFailures: [String]?
        var cleanupFailureCount: Int?
        var failedStage: String?
        var errorDomain: String?
        var errorCode: Int?
        var controlPhase: String?
        var message: String?
    }
    private let lock = NSLock()
    private let output: URL
    private var snapshot: Snapshot
    private var finished = false

    init(mode: String, root: URL, operation: String? = nil, identifier: String? = nil, domainID: String? = nil) throws {
        output = root.appendingPathComponent("\(mode)-result.json")
        snapshot = Snapshot(mode: mode, bundle: String((Bundle.main.bundleIdentifier ?? "unknown").prefix(128)),
                            operation: operation, identifier: identifier, domainID: domainID)
        #if MYDRIVE_DEVELOPMENT
        if mode == "session" {
            snapshot.credentialLifetime = "15minutes-encrypted-provider-keychain"
            snapshot.persistence = true
        }
        if mode == "local-network" {
            snapshot.networkEndpoint = try DevelopmentConnectionScope.settings(domainID: "unas-test").host
        }
        #endif
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try stage("started")
    }

    func stage(_ name: String, registration: String? = nil, finderRoot: String? = nil,
               credentialRead: String? = nil, terminal: Bool = false) throws {
        try lock.withLock {
            guard !finished else { return }
            advance(name)
            if let registration { snapshot.registration = registration }
            if let credentialRead { snapshot.credential_read = credentialRead }
            if let finderRoot { snapshot.finderRoot = String(finderRoot.prefix(1024)) }
            try write()
            finished = terminal
        }
    }

    func completeControl(message: String, preservedURL: URL? = nil, cleanupFailures: [String] = []) throws {
        try lock.withLock {
            guard !finished else { return }
            snapshot.message = String(message.prefix(512))
            snapshot.preservedURL = preservedURL?.absoluteString
            snapshot.cleanupFailures = Array(cleanupFailures.prefix(8)).map { String($0.prefix(256)) }
            snapshot.cleanupFailureCount = cleanupFailures.count
            advance("complete")
            try write()
            finished = true
        }
    }

    #if MYDRIVE_DEVELOPMENT
    func networkObservation(state: String, pathStatus: String?, unsatisfiedReason: String?, error: NSError?) throws {
        try lock.withLock {
            guard !finished else { return }
            snapshot.networkState = String(state.prefix(32))
            snapshot.pathStatus = pathStatus.map { String($0.prefix(32)) }
            snapshot.unsatisfiedReason = unsatisfiedReason.map { String($0.prefix(64)) }
            snapshot.networkErrorDomain = error.map { String($0.domain.prefix(128)) }
            snapshot.networkErrorCode = error?.code
            advance(state)
            try write()
        }
    }
    #endif

    func fail(_ error: Error, redacting secret: String?) {
        lock.withLock { failure(error, secret: secret, stage: "failed") }
    }

    func timeout() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            failure(probeError(124, "Diagnostic exceeded its 120-second lifetime limit."), secret: nil, stage: "timed_out")
            return true
        }
    }

    private func failure(_ error: Error, secret: String?, stage: String) {
        guard !finished else { return }
        let error = error as NSError
        let clean: (String, Int) -> String = { value, limit in
            String((secret.map { value.replacingOccurrences(of: $0, with: "[redacted]") } ?? value).prefix(limit))
        }
        snapshot.failedStage = snapshot.stage
        advance(stage)
        snapshot.errorDomain = clean(error.domain, 128)
        snapshot.errorCode = error.code
        if let phase = error.userInfo["MyDriveControlPhase"] as? String {
            snapshot.controlPhase = clean(phase, 64)
        }
        snapshot.message = clean(error.localizedDescription, 512)
        if let failures = error.userInfo["MyDriveCleanupFailures"] as? [String] {
            snapshot.cleanupFailures = Array(failures.prefix(8)).map { clean($0, 256) }
            snapshot.cleanupFailureCount = failures.count
        }
        if snapshot.mode == "credential" { snapshot.credential_read = "unavailable" }
        else if snapshot.mode == "registration" || snapshot.mode == "connection", snapshot.registration == nil {
            snapshot.registration = stage == "timed_out" ? "unconfirmed" : "rejected"
        }
        try? write()
        finished = true
    }

    private func advance(_ stage: String) {
        snapshot.stage = stage
        snapshot.stages.append(stage)
        snapshot.stages = Array(snapshot.stages.suffix(16))
    }

    private func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= 16 * 1024 else { throw probeError(6, "Diagnostic report exceeded its size limit.") }
        try data.write(to: output, options: .atomic)
    }
}
