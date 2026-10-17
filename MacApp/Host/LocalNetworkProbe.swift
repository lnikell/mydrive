#if MYDRIVE_DEVELOPMENT
import Foundation
import Network

/// Own one TCP connection while the system handles ordinary LAN permission.
/// No application bytes are sent; waiting is deliberately nonterminal. All
/// Network callbacks run on queue, and every terminal path uses the same gate.
final class LocalNetworkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.mydrive.local-network-probe")
    private let connection: NWConnection
    private let report: ProbeReport
    private let timeout: TimeInterval
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var deadline: DispatchWorkItem?
    private var observedState = "setup" // queue-confined

    @MainActor static func requestAccess(for settings: ConnectionSettings, report: ProbeReport) async throws {
        guard AppStorage.isDevelopmentStorage, settings.domainID == "unas-test",
              (try? DevelopmentConnectionScope.validate(settings)) != nil else {
            throw probeError(9, "Local-network diagnostics require the fixed development endpoint.")
        }
        guard let endpoint = URLComponents(string: "smb://" + settings.host),
              endpoint.user == nil, endpoint.password == nil, endpoint.path.isEmpty,
              endpoint.query == nil, endpoint.fragment == nil, let host = endpoint.host, !host.isEmpty,
              let portNumber = UInt16(exactly: endpoint.port ?? 445),
              let port = NWEndpoint.Port(rawValue: portNumber), portNumber > 0 else {
            throw probeError(9, "The fixed development server address is invalid.")
        }
        let hostname = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let connection = NWConnection(host: NWEndpoint.Host(hostname), port: port, using: .tcp)
        try await LocalNetworkProbe(connection: connection, report: report).run()
    }

    /// Internal seam permits loopback-only connection and lifetime tests.
    init(connection: NWConnection, report: ProbeReport, timeout: TimeInterval = 118) {
        self.connection = connection
        self.report = report
        self.timeout = timeout
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed: Result<Void, Error>? = lock.withLock {
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) }
                else { queue.async { [weak self] in self?.start() } }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func start() {
        guard lock.withLock({ result == nil }) else { return }
        connection.stateUpdateHandler = { @Sendable [weak self] state in self?.update(state) }
        connection.pathUpdateHandler = { @Sendable [weak self] _ in self?.observe(error: nil) }
        let timer = DispatchWorkItem { @Sendable [weak self] in
            self?.finish(.failure(probeError(124, "Local-network connection did not become ready before the diagnostic deadline.")))
        }
        let active = lock.withLock {
            guard result == nil else { return false }
            deadline = timer
            return true
        }
        guard active else { timer.cancel(); return }
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        connection.start(queue: queue)
    }

    private func update(_ state: NWConnection.State) {
        guard lock.withLock({ result == nil }) else { return }
        switch state {
        case .setup: observedState = "setup"; observe(error: nil)
        case .preparing: observedState = "preparing"; observe(error: nil)
        case .waiting(let error): observedState = "waiting"; observe(error: error)
        case .ready:
            observedState = "ready"
            observe(error: nil)
            finish(.success(()))
        case .failed(let error):
            observedState = "failed"
            observe(error: error)
            finish(.failure(error))
        case .cancelled: finish(.failure(CancellationError()))
        @unknown default: finish(.failure(probeError(10, "Unknown local-network connection state.")))
        }
    }

    private func observe(error: NWError?) {
        guard lock.withLock({ result == nil }) else { return }
        let path = connection.currentPath
        do {
            try report.networkObservation(state: observedState,
                pathStatus: path.map { String(describing: $0.status) },
                unsatisfiedReason: path.flatMap { $0.status == .unsatisfied ? String(describing: $0.unsatisfiedReason) : nil },
                error: error.map { $0 as NSError })
        } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        let owned = lock.withLock { () -> (CheckedContinuation<Void, Error>?, DispatchWorkItem?)? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil; deadline = nil }
            return (continuation, deadline)
        }
        guard let owned else { return }
        owned.1?.cancel()
        let reply = owned.0
        // Cancel before resuming the caller, which may terminate the host.
        queue.async { [connection, reply] in
            connection.stateUpdateHandler = nil
            connection.pathUpdateHandler = nil
            connection.cancel()
            reply?.resume(with: result)
        }
    }
}
#endif
