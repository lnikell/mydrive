import Foundation
import MyDriveCore

enum SMBClientError: LocalizedError, Sendable {
    case authenticationRequired, serverUnreachable, invalidResponse, cancelled
    case permissionDenied, itemMissing, diskFull, changed
    case localFailure(String), remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "The NAS credentials need attention."
        case .serverUnreachable: "The NAS is unavailable. Downloaded files remain on this Mac."
        case .invalidResponse: "The NAS experiment returned an incomplete response."
        case .cancelled: "The transfer was cancelled."
        case .permissionDenied: "The NAS account cannot access this item."
        case .itemMissing: "This item is no longer on the NAS."
        case .diskFull: "There is not enough space to complete the operation."
        case .changed: "The NAS file changed. Try opening its current version."
        case .localFailure(let message), .remoteFailure(let message): message
        }
    }
}

private struct TransportEntry: Decodable, Sendable {
    let name: String
    let bytes: Int64
    let directory: Bool
    let modified_filetime: UInt64
    let changed_filetime: UInt64
    let attributes: UInt32

    var observation: RemoteEntry {
        RemoteEntry(name: name, kind: directory ? .directory : .file,
                    contentVersion: "\(bytes):\(modified_filetime):\(changed_filetime)",
                    metadataVersion: "\(attributes):\(changed_filetime)", size: bytes,
                    modifiedAt: Date(timeIntervalSince1970: Double(modified_filetime) / 10_000_000 - 11_644_473_600))
    }
}

private struct TransportEvent: Decodable {
    let type: String
    let code: String?
    let entries: [TransportEntry]?
    let bytes: Int64?
    let message: String?
    let result: Completion?

    struct Completion: Decodable, Sendable { let complete: Bool?; let bytes: Int64?; let entry: TransportEntry? }

    private enum CodingKeys: String, CodingKey { case type, code, entries, bytes, message, result }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        code = try values.decodeIfPresent(String.self, forKey: .code)
        entries = try values.decodeIfPresent(BoundedEntries.self, forKey: .entries)?.values
        bytes = try values.decodeIfPresent(Int64.self, forKey: .bytes)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        result = try values.decodeIfPresent(Completion.self, forKey: .result)
    }
}

/// Remote names are protocol data, not macOS filesystem arguments. Foundation
/// Process may decompose Unicode in argv; JSON stdin preserves their UTF-8 form.
private enum TransportOperation: Encodable, Sendable {
    case probe
    case list(path: String)
    case read(path: String, destination: String)

    var command: String {
        switch self {
        case .probe: "probe"
        case .list: "list"
        case .read: "read"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, path, destination }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(command, forKey: .type)
        switch self {
        case .probe: break
        case .list(let path): try values.encode(path, forKey: .path)
        case .read(let path, let destination):
            try values.encode(path, forKey: .path)
            try values.encode(destination, forKey: .destination)
        }
    }
}

private struct TransportRequest: Encodable {
    let version = 1
    let host: String
    let share: String
    let username: String
    let password: String
    let operation: TransportOperation

    func encoded() throws -> Data {
        guard (1...4096).contains(password.utf8.count) else { throw SMBClientError.authenticationRequired }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 65_536 else { throw HelperOperationError.oversizedInput }
        return data
    }
}

/// Experiment adapter: one helper process owns a bounded SMB operation. The
/// caller sees pages/files, not subprocess or credential lifetime management.
struct SMBClient: Sendable {
    let settings: ConnectionSettings
    #if MYDRIVE_DEVELOPMENT
    private let developmentPasswordOverride: String?
    private let developmentHelperURL: URL?

    init(settings: ConnectionSettings) {
        self.settings = settings
        self.developmentPasswordOverride = nil
        self.developmentHelperURL = nil
    }

    init(settings: ConnectionSettings, developmentPassword: String, helperURL: URL? = nil) {
        self.settings = settings
        self.developmentPasswordOverride = developmentPassword
        self.developmentHelperURL = helperURL
    }
    #else
    init(settings: ConnectionSettings) { self.settings = settings }
    #endif

    func probe() async throws {
        try await run(.probe)
    }

    func probe(password: String) async throws {
        try await run(.probe, passwordOverride: password)
    }

    func list(path: String, pageSize: Int = 128,
              onPage: @escaping @Sendable ([RemoteEntry]) async throws -> Void) async throws {
        guard (1...1000).contains(pageSize) else { throw SMBClientError.invalidResponse }
        try await run(.list(path: path), onPage: { entries in
            for offset in stride(from: 0, to: entries.count, by: pageSize) {
                try await onPage(Array(entries[offset..<min(offset + pageSize, entries.count)]))
            }
        })
    }

    func download(path: String, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> RemoteEntry {
        let result = try await run(.read(path: path, destination: destination.path), progress: progress)
        guard let entry = result?.entry else {
            try? FileManager.default.removeItem(at: destination)
            throw SMBClientError.invalidResponse
        }
        return entry.observation
    }

    @discardableResult private func run(_ operation: TransportOperation,
                     passwordOverride: String? = nil,
                     onPage: (@Sendable ([RemoteEntry]) async throws -> Void)? = nil,
                     progress: (@Sendable (Int64) -> Void)? = nil) async throws -> TransportEvent.Completion? {
        try Task.checkCancellation()
        let receiver = TransportReceiver(command: operation.command, onPage: onPage, progress: progress)
        #if MYDRIVE_DEVELOPMENT
        let password = try passwordOverride ?? developmentPasswordOverride ?? CredentialStore.password(for: settings)
        let helperURL = try developmentHelperURL ?? AppStorage.transportURL()
        #else
        let password = try passwordOverride ?? CredentialStore.password(for: settings)
        let helperURL = try AppStorage.transportURL()
        #endif
        let input = try TransportRequest(host: settings.host, share: settings.share,
                                         username: settings.username, password: password,
                                         operation: operation).encoded()
        try await HelperOperation.run(
            executable: helperURL, arguments: ["--request-stdin"], input: input
        ) { frame in try await receiver.receive(frame) }
        return try await receiver.completion()
    }
}

/// The JSONL protocol has one connected event and one terminal complete event.
/// Page size is checked during decoding, before allocating an unbounded array.
private actor TransportReceiver {
    let command: String
    let onPage: (@Sendable ([RemoteEntry]) async throws -> Void)?
    let progress: (@Sendable (Int64) -> Void)?
    private var connected = false
    private var complete = false
    private var lastProgress: Int64 = 0
    private var result: TransportEvent.Completion?

    init(command: String, onPage: (@Sendable ([RemoteEntry]) async throws -> Void)?,
         progress: (@Sendable (Int64) -> Void)?) {
        self.command = command
        self.onPage = onPage
        self.progress = progress
    }

    func receive(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !complete else { throw SMBClientError.invalidResponse }
        let event: TransportEvent
        do { event = try JSONDecoder().decode(TransportEvent.self, from: data) }
        catch { throw SMBClientError.invalidResponse }
        if event.type == "error" { throw Self.mapError(event) }
        if event.type == "connected" {
            guard !connected else { throw SMBClientError.invalidResponse }
            connected = true
            return
        }
        guard connected else { throw SMBClientError.invalidResponse }
        switch event.type {
        case "page":
            guard command == "list", let entries = event.entries else { throw SMBClientError.invalidResponse }
            try await onPage?(entries.map(\.observation))
        case "progress":
            guard command == "read", let bytes = event.bytes, bytes >= lastProgress else {
                throw SMBClientError.invalidResponse
            }
            if bytes > lastProgress {
                lastProgress = bytes
                progress?(bytes)
            }
        case "complete":
            guard let result = event.result else { throw SMBClientError.invalidResponse }
            if command == "list", result.complete != true { throw SMBClientError.invalidResponse }
            if command == "read" {
                guard let entry = result.entry, !entry.directory, entry.bytes >= 0,
                      result.bytes == entry.bytes, entry.bytes >= lastProgress else {
                    throw SMBClientError.invalidResponse
                }
            }
            self.result = result
            complete = true
            if command == "read", let bytes = result.bytes { progress?(bytes) }
        default: throw SMBClientError.invalidResponse
        }
    }

    func completion() throws -> TransportEvent.Completion? {
        guard complete else { throw SMBClientError.invalidResponse }
        return result
    }

    private static func mapError(_ event: TransportEvent) -> SMBClientError {
        let message = event.message ?? "NAS operation failed."
        switch event.code {
        case "auth_required", "session_expired", "guest_refused": return .authenticationRequired
        case "cancelled": return .cancelled
        case "access_denied": return .permissionDenied
        case "not_found": return .itemMissing
        case "disk_full": return .diskFull
        case "changed", "resume_refused": return .changed
        case "connection_lost", "timed_out", "transport_io": return .serverUnreachable
        case "local_io": return .localFailure(message)
        default: return .remoteFailure(message)
        }
    }
}

private struct BoundedEntries: Decodable {
    let values: [TransportEntry]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let count = container.count, count > 1000 { throw SMBClientError.invalidResponse }
        var values: [TransportEntry] = []
        while !container.isAtEnd {
            guard values.count < 1000 else { throw SMBClientError.invalidResponse }
            values.append(try container.decode(TransportEntry.self))
        }
        self.values = values
    }
}
