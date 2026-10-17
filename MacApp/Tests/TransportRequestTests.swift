#if MYDRIVE_DEVELOPMENT
import Foundation
import MyDriveCore

private actor RequestPages {
    var names: [String] = []
    func append(_ entries: [RemoteEntry]) { names += entries.map(\.name) }
}

private final class ByteSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int64] = []
    func append(_ bytes: Int64) { lock.withLock { samples.append(bytes) } }
    var values: [Int64] { lock.withLock { samples } }
}

/// Runs the real SMBClient + HelperOperation + Process path against a local
/// protocol fixture. No Keychain, application domain, permission or NAS access.
@main struct TransportRequestTests {
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "TransportRequestTests", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func unhex(_ value: String) throws -> Data {
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2) else { throw SMBClientError.invalidResponse }
        var result = Data()
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[offset..<(offset + 2)], as: UTF8.self), radix: 16) else {
                throw SMBClientError.invalidResponse
            }
            result.append(byte)
        }
        return result
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw SMBClientError.invalidResponse }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let composed = "Caf\u{e9}/\u{c5}ngstr\u{f6}m-\u{65e5}\u{672c}\u{8a9e}.txt"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        try check(Data(composed.utf8) != Data(decomposed.utf8), "Unicode fixtures have identical wire bytes")
        let secret = "synthetic-\u{e9}\nsecond line\r\n"
        let settings = ConnectionSettings(domainID: "synthetic", displayName: "Synthetic only",
            host: "--synthetic.invalid", share: "Partag\u{e9}-" + decomposed,
            username: "Utilis\u{e9}-" + decomposed)
        let client = SMBClient(settings: settings, developmentPassword: secret, helperURL: helper)

        for path in [composed, decomposed, "--replace", "folder/--password-stdin", ""] {
            let pages = RequestPages()
            try await client.list(path: path) { await pages.append($0) }
            let names = await pages.names
            try check(names.count == 1, "The local helper did not observe one complete request")
            let wire = try unhex(names[0])
            let request = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
            for (key, expected) in [("host", settings.host), ("share", settings.share),
                                    ("username", settings.username), ("password", secret)] {
                let actual = request[key] as? String
                try check(actual.map { Data($0.utf8) } == Data(expected.utf8), "A request string changed UTF-8 bytes")
            }
            let operation = request["operation"] as! [String: String]
            try check(operation["type"] == "list" && operation["path"].map { Data($0.utf8) } == Data(path.utf8),
                      "A remote path changed UTF-8 bytes or became an option")
        }
        print("PASS real subprocess preserves NFC/NFD names, endpoint strings, option-like paths and newline secrets")

        try await client.probe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mydrive-transport-request-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, path) in [composed, decomposed, "--looks-like-an-option"].enumerated() {
            let destination = root.appendingPathComponent("\(index)-r\u{e9}sultat.txt")
            let observation = try await client.download(path: path, to: destination) { _ in }
            try check(try Data(contentsOf: destination) == Data(path.utf8), "Read request changed the remote or local path")
            try check(observation.size == Int64(path.utf8.count), "Read completion metadata did not match fixture content")
        }
        print("PASS typed probe/read requests, Unicode local destinations and complete response routing")

        for (mode, expected): (String, [Int64]) in [
            ("small", [1, 10, 20]), ("large", [1, 1 << 32, (1 << 32) + 20]), ("empty", [0])
        ] {
            let samples = ByteSamples()
            let observation = try await client.download(path: "__progress__/" + mode,
                to: root.appendingPathComponent(mode), progress: samples.append)
            try check(samples.values == expected && observation.size == expected.last,
                      "Real subprocess lost monotonic or exact terminal byte counts")
        }
        print("PASS small, large Int64 and empty downloads report exact terminal bytes without duplicate samples")

        for (mode, expected): (String, [Int64]) in [
            ("decreasing", [10]), ("negative", []), ("terminal-decreasing", [21]), ("integer-overflow", [])
        ] {
            let samples = ByteSamples()
            var rejected = false
            do {
                _ = try await client.download(path: "__progress__/" + mode,
                    to: root.appendingPathComponent(mode), progress: samples.append)
            } catch SMBClientError.invalidResponse { rejected = true }
            try check(rejected && samples.values == expected,
                      "Invalid progress reached its callback or published terminal success")
        }
        var nonReadRejected = false
        do { try await client.list(path: "__progress__/wrong-command") { _ in } }
        catch SMBClientError.invalidResponse { nonReadRejected = true }
        try check(nonReadRejected, "A non-read operation accepted byte progress")
        print("PASS decreasing, negative, overflowing and non-read progress fail before terminal success")

        let samples = ByteSamples()
        let stream = AsyncStream<Int64>.makeStream()
        let cancelled = Task {
            defer { stream.continuation.finish() }
            return try await client.download(path: "__progress__/cancel", to: root.appendingPathComponent("cancel")) {
                samples.append($0)
                stream.continuation.yield($0)
            }
        }
        var iterator = stream.stream.makeAsyncIterator()
        try check(await iterator.next() == 1, "Cancellation fixture did not report a real first sample")
        cancelled.cancel()
        var wasCancelled = false
        do { _ = try await cancelled.value }
        catch is CancellationError { wasCancelled = true }
        try check(wasCancelled && samples.values == [1], "Cancellation published more bytes or terminal completion")
        print("PASS cancellation after subprocess progress reaps the helper without terminal success")

        let largestPassword = String(repeating: "\u{e9}", count: 2048)
        try await SMBClient(settings: settings, developmentPassword: largestPassword, helperURL: helper).probe()
        for password in ["", largestPassword + "\u{e9}"] {
            do {
                try await SMBClient(settings: settings, developmentPassword: password, helperURL: helper).probe()
                throw SMBClientError.invalidResponse
            } catch SMBClientError.authenticationRequired { }
        }
        do {
            try await client.list(path: String(repeating: "x", count: 65_536)) { _ in }
            throw SMBClientError.invalidResponse
        } catch HelperOperationError.oversizedInput { }
        print("PASS UTF-8 password limit and bounded complete request fail before launch")
    }
}
#endif
