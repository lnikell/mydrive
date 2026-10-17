#if MYDRIVE_DEVELOPMENT
import Foundation
import FileProvider
import Network
import Darwin

/// Optimized, loopback-only checks; no NAS, credentials or permission changes.
@main struct LocalNetworkProbeTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "LocalNetworkProbeTests", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mydrive-local-network-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = NSFileProviderError(.serverUnreachable) as NSError
        let phased = DomainControlOperation<Int>(timeout: 2)
        let failureReport = try ProbeReport(mode: "control", root: root)
        do {
            _ = try await phased.run {
                phased.finish(.failure(original), phase: .serviceLookup)
            }
            throw NSError(domain: "LocalNetworkProbeTests", code: 10)
        } catch let error as NSError {
            failureReport.fail(error, redacting: nil)
        }
        let failure = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("control-result.json"))) as! [String: Any]
        try check(failure["errorDomain"] as? String == original.domain && failure["errorCode"] as? Int == original.code,
                  "Control report changed the original OS error classification.")
        try check(failure["controlPhase"] as? String == "service_lookup" &&
                  failure["message"] as? String == original.localizedDescription,
                  "Control phase leaked into the user-facing message or was absent from diagnostics.")
        print("PASS control reports separate request phase from the original error message")

        let secret = "synthetic-report-secret"
        let boundedReport = try ProbeReport(mode: "bounded", root: root)
        boundedReport.fail(NSError(domain: "ReportTest", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "A synthetic failure.",
            "MyDriveControlPhase": secret + String(repeating: "x", count: 100)
        ]), redacting: secret)
        let bounded = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("bounded-result.json"))) as! [String: Any]
        let boundedPhase = bounded["controlPhase"] as? String
        try check(boundedPhase?.count == 64 && boundedPhase?.hasPrefix("[redacted]") == true &&
                  boundedPhase?.contains(secret) == false,
                  "Control phase diagnostic was unbounded or bypassed report redaction.")
        let unphasedReport = try ProbeReport(mode: "unphased", root: root)
        unphasedReport.fail(NSError(domain: "ReportTest", code: 8,
                                  userInfo: ["MyDriveControlPhase": 42]), redacting: nil)
        let unphased = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("unphased-result.json"))) as! [String: Any]
        try check(unphased["controlPhase"] == nil, "Invalid phase metadata was included in a diagnostic report.")
        print("PASS control phase diagnostics are bounded, redacted and type-checked")

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0, let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: address.sin_port)) else {
            throw NSError(domain: "LocalNetworkProbeTests", code: 2)
        }

        let report = try ProbeReport(mode: "local-network", root: root)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        weak var released: LocalNetworkProbe?
        do {
            let owner = LocalNetworkProbe(connection: connection, report: report, timeout: 3)
            released = owner
            try await owner.run()
        }
        try await Task.sleep(for: .milliseconds(20))
        try check(released == nil, "Successful connection retained its owner.")
        let observation = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("local-network-result.json"))) as! [String: Any]
        try check(observation["networkState"] as? String == "ready", "Success did not record readiness.")
        print("PASS loopback TCP readiness, report and owner release")

        for _ in 0..<100 {
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            let owner = LocalNetworkProbe(connection: connection, report: report, timeout: 3)
            let task = Task { try await owner.run() }
            task.cancel()
            do {
                try await task.value
                throw NSError(domain: "LocalNetworkProbeTests", code: 3)
            } catch is CancellationError { }
        }
        print("PASS 100 pre-bind cancellation races")

        // Port zero cannot become a TCP peer. Network.framework reports this
        // as waiting, providing a deterministic local-only pending operation.
        let waiting = NWConnection(host: "127.0.0.1", port: .any, using: .tcp)
        weak var cancelledOwner: LocalNetworkProbe?
        do {
            let owner = LocalNetworkProbe(connection: waiting, report: report, timeout: 3)
            cancelledOwner = owner
            let task = Task { try await owner.run() }
            try await Task.sleep(for: .milliseconds(30))
            task.cancel()
            do {
                try await task.value
                throw NSError(domain: "LocalNetworkProbeTests", code: 5)
            } catch is CancellationError { }
        }
        try await Task.sleep(for: .milliseconds(20))
        try check(cancelledOwner == nil, "Cancelled connection retained its owner.")
        try check(waiting.state == .cancelled, "Cancelled request left a connection running.")
        print("PASS pending connection cancellation, transport cleanup and owner release")

        let pending = NWConnection(host: "127.0.0.1", port: .any, using: .tcp)
        let timed = LocalNetworkProbe(connection: pending, report: report, timeout: 0.02)
        do {
            try await timed.run()
            throw NSError(domain: "LocalNetworkProbeTests", code: 6)
        } catch let error as NSError {
            try check(error.domain == "MyDriveDiagnostic" && error.code == 124, "Pending operation missed its deadline.")
        }
        try await Task.sleep(for: .milliseconds(10))
        try check(pending.state == .cancelled, "Timed-out request left a connection running.")
        print("PASS pending connection deadline and transport cleanup")

        let settings = ConnectionSettings(domainID: "unas-test", displayName: "Test", host: "127.0.0.1:445",
                                          share: "mydrive-test", username: "mydrive-test")
        do {
            try await LocalNetworkProbe.requestAccess(for: settings, report: report)
            throw NSError(domain: "LocalNetworkProbeTests", code: 4)
        } catch let error as NSError {
            try check(error.domain == "MyDriveDiagnostic" && error.code == 9, "Nonfixed endpoint was accepted.")
        }
        print("PASS fixed-endpoint gate rejects loopback before connection")
    }
}
#endif
