import Foundation
import MyDriveCore

enum SMBClientError: LocalizedError, Sendable {
    case authenticationRequired, serverUnreachable, invalidResponse, cancelled
    case permissionDenied, itemMissing, diskFull, changed, unsupportedFeature, scopeChanged
    case localFailure(String), remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "The NAS credentials need attention."
        case .serverUnreachable: "The NAS is unavailable. Downloaded files remain on this Mac."
        case .invalidResponse: "The drive operation could not be verified. Try again."
        case .cancelled: "The transfer was cancelled."
        case .permissionDenied: "The NAS account cannot access this item."
        case .itemMissing: "This item is no longer on the NAS."
        case .diskFull: "There is not enough space to complete the operation."
        case .changed: "The NAS file changed. Try opening its current version."
        case .unsupportedFeature: "This NAS file uses a feature that MyDrive cannot transfer safely yet."
        case .scopeChanged: "The selected folder moved or was replaced. Refresh the drive before trying again."
        case .localFailure(let message), .remoteFailure(let message): message
        }
    }
}

struct SMBEntry: Codable, Equatable, Sendable {
    let name: String
    let bytes: Int64
    let directory: Bool
    let index_number: UInt64?
    let created_filetime: UInt64
    let modified_filetime: UInt64
    let changed_filetime: UInt64
    let attributes: UInt32

    var objectIdentity: RemoteObjectIdentity? {
        guard let index_number, index_number != 0, created_filetime != 0 else { return nil }
        return RemoteObjectIdentity(indexNumber: index_number, createdFiletime: created_filetime)
    }

    var observation: RemoteEntry {
        RemoteEntry(name: name, kind: attributes & 0x400 != 0 ? .symbolicLink : directory ? .directory : .file,
                    contentVersion: "smb-v2:\(index_number ?? 0):\(created_filetime):\(bytes):\(modified_filetime):\(changed_filetime)",
                    metadataVersion: "smb-v2:\(attributes):\(created_filetime):\(changed_filetime)", size: bytes,
                    modifiedAt: Date(timeIntervalSince1970: Double(modified_filetime) / 10_000_000 - 11_644_473_600),
                    objectIdentity: objectIdentity)
    }
}

private struct TransportEvent: Decodable {
    let type: String
    let code: String?
    let entries: [SMBEntry]?
    let bytes: Int64?
    let message: String?
    let result: Completion?
    let entry: SMBEntry?

    struct Completion: Decodable, Sendable {
        let complete: Bool?
        let entryPresent: Bool
        let bytes: Int64?
        let entry: SMBEntry?
        let operation_id: String?
        let outcome: SMBMutationResult.Outcome?
        let code: String?
        let sha256: String?
        let cleanup_pending: Bool?
        let staged: SMBMutationRequest.Artifact?
        let archived: SMBMutationRequest.Artifact?
        let save_contract: MutationSaveContract?
        let content_evidence: MutationContentEvidence?

        private enum CodingKeys: String, CodingKey {
            case complete, bytes, entry, operation_id, outcome, code, sha256, cleanup_pending, staged, archived, save_contract, content_evidence
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            complete = try values.decodeIfPresent(Bool.self, forKey: .complete)
            bytes = try values.decodeIfPresent(Int64.self, forKey: .bytes)
            entryPresent = values.contains(.entry)
            entry = try values.decodeIfPresent(SMBEntry.self, forKey: .entry)
            operation_id = try values.decodeIfPresent(String.self, forKey: .operation_id)
            outcome = try values.decodeIfPresent(SMBMutationResult.Outcome.self, forKey: .outcome)
            code = try values.decodeIfPresent(String.self, forKey: .code)
            sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
            cleanup_pending = try values.decodeIfPresent(Bool.self, forKey: .cleanup_pending)
            staged = try values.decodeIfPresent(SMBMutationRequest.Artifact.self, forKey: .staged)
            archived = try values.decodeIfPresent(SMBMutationRequest.Artifact.self, forKey: .archived)
            save_contract = try values.decodeIfPresent(MutationSaveContract.self, forKey: .save_contract)
            content_evidence = try values.decodeIfPresent(MutationContentEvidence.self, forKey: .content_evidence)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, code, entries, bytes, message, result, entry }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        code = try values.decodeIfPresent(String.self, forKey: .code)
        entries = try values.decodeIfPresent(BoundedEntries.self, forKey: .entries)?.values
        bytes = try values.decodeIfPresent(Int64.self, forKey: .bytes)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        result = try values.decodeIfPresent(Completion.self, forKey: .result)
        entry = try values.decodeIfPresent(SMBEntry.self, forKey: .entry)
    }
}

/// Remote names are protocol data, not macOS filesystem arguments. Foundation
/// Process may decompose Unicode in argv; JSON stdin preserves their UTF-8 form.
private enum TransportOperation: Encodable, Sendable {
    case probe
    case list(path: String, deleteScope: SMBDeleteScope?, treeScope: SMBTreeScope?)
    case observedList(path: String)
    case read(path: String, destination: String, treeScope: SMBTreeScope?)
    case hydrate(path: String, destination: String)
    case stat(path: String, deleteScope: SMBDeleteScope?, treeScope: SMBTreeScope?)
    case mutate(SMBMutationRequest)
    case reconcile(SMBMutationRequest)

    var command: String {
        switch self {
        case .probe: "probe"
        case .list: "list"
        case .observedList: "observed_list"
        case .read: "read"
        case .hydrate: "hydrate"
        case .stat: "stat"
        case .mutate: "mutate"
        case .reconcile: "reconcile"
        }
    }

    var uploadLimit: Int64? {
        if case .mutate(let request) = self { return request.payload?.bytes }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case type, path, destination, request, delete_scope, tree_scope }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(command, forKey: .type)
        switch self {
        case .probe: break
        case .list(let path, let scope, let treeScope), .stat(let path, let scope, let treeScope):
            try values.encode(path, forKey: .path)
            try values.encodeIfPresent(scope, forKey: .delete_scope)
            try values.encodeIfPresent(treeScope, forKey: .tree_scope)
        case .observedList(let path):
            try values.encode(path, forKey: .path)
        case .read(let path, let destination, let treeScope):
            try values.encode(path, forKey: .path)
            try values.encode(destination, forKey: .destination)
            try values.encodeIfPresent(treeScope, forKey: .tree_scope)
        case .hydrate(let path, let destination):
            try values.encode(path, forKey: .path)
            try values.encode(destination, forKey: .destination)
        case .mutate(let request), .reconcile(let request):
            try values.encode(request, forKey: .request)
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

    @discardableResult
    func list(path: String, pageSize: Int = 128,
              onPage: @escaping @Sendable ([RemoteEntry]) async throws -> Void) async throws -> RemoteObjectIdentity {
        let directory = try await listDirectory(path: path, pageSize: pageSize, onPage: onPage)
        guard let identity = directory.objectIdentity else { throw SMBClientError.invalidResponse }
        return identity
    }

    func listDirectory(path: String, pageSize: Int = 128, deleteScope: SMBDeleteScope? = nil,
                       treeScope: SMBTreeScope? = nil,
                       onPage: @escaping @Sendable ([RemoteEntry]) async throws -> Void) async throws -> SMBEntry {
        guard (1...1000).contains(pageSize) else { throw SMBClientError.invalidResponse }
        if let deleteScope, !deleteScope.contains(path) { throw SMBClientError.invalidResponse }
        if let treeScope, !treeScope.isValid || !treeScope.contains(path) { throw SMBClientError.invalidResponse }
        guard deleteScope == nil || treeScope == nil else { throw SMBClientError.invalidResponse }
        let result = try await run(.list(path: path, deleteScope: deleteScope, treeScope: treeScope), onPage: { entries in
            for offset in stride(from: 0, to: entries.count, by: pageSize) {
                try await onPage(Array(entries[offset..<min(offset + pageSize, entries.count)]))
            }
        })
        guard let directory = result?.entry, directory.directory,
              directory.attributes & 0x400 == 0, directory.objectIdentity != nil else {
            throw SMBClientError.invalidResponse
        }
        return directory
    }

    /// The receiver binds every page to its initial same-handle observation.
    func listObservedDirectory(
        path: String, onPage: @escaping @Sendable (RemoteEntry, [RemoteEntry]) async throws -> Void
    ) async throws -> RemoteEntry {
        let result = try await run(.observedList(path: path), onObservedPage: onPage)
        guard let directory = result?.entry, directory.directory,
              directory.attributes & 0x400 == 0, directory.objectIdentity != nil else {
            throw SMBClientError.invalidResponse
        }
        return directory.observation
    }

    func download(path: String, to destination: URL, treeScope: SMBTreeScope? = nil,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> RemoteEntry {
        if let treeScope, !treeScope.isValid || !treeScope.containsPayload(path) { throw SMBClientError.invalidResponse }
        return try await download(.read(path: path, destination: destination.path, treeScope: treeScope),
                                  to: destination, progress: progress)
    }

    /// File Provider replica hydration has an explicit synchronization purpose.
    /// Mutation verification and private tree reads keep the strict read API.
    func downloadForHydration(path: String, to destination: URL,
                              progress: @escaping @Sendable (Int64) -> Void) async throws -> RemoteEntry {
        try await download(.hydrate(path: path, destination: destination.path), to: destination, progress: progress)
    }

    private func download(_ operation: TransportOperation, to destination: URL,
                          progress: @escaping @Sendable (Int64) -> Void) async throws -> RemoteEntry {
        let result = try await run(operation, progress: progress)
        guard let entry = result?.entry else {
            try? FileManager.default.removeItem(at: destination)
            throw SMBClientError.invalidResponse
        }
        return entry.observation
    }

    func stat(path: String, deleteScope: SMBDeleteScope? = nil, treeScope: SMBTreeScope? = nil) async throws -> SMBEntry? {
        if let deleteScope, !deleteScope.contains(path) { throw SMBClientError.invalidResponse }
        if let treeScope, !treeScope.isValid || !treeScope.contains(path) { throw SMBClientError.invalidResponse }
        guard deleteScope == nil || treeScope == nil else { throw SMBClientError.invalidResponse }
        guard let result = try await run(.stat(path: path, deleteScope: deleteScope, treeScope: treeScope)), result.entryPresent else {
            throw SMBClientError.invalidResponse
        }
        if let entry = result.entry, entry.bytes < 0 { throw SMBClientError.invalidResponse }
        return result.entry
    }

    func mutate(_ request: SMBMutationRequest, reconcile: Bool = false,
                progress: (@Sendable (Int64) -> Void)? = nil) async throws -> SMBMutationResult {
        guard request.parent.isValid,
              (request.kind == .move ? request.destination_parent?.isValid == true : request.destination_parent == nil) else {
            throw SMBClientError.invalidResponse
        }
        if let scope = request.delete_scope {
            guard scope.contains(request.path), [.delete, .cleanup].contains(request.kind) else { throw SMBClientError.invalidResponse }
        }
        guard request.delete_scope == nil || request.tree_scope == nil else { throw SMBClientError.invalidResponse }
        if let scope = request.tree_scope, !scope.isValid || !scope.contains(request.path) { throw SMBClientError.invalidResponse }
        try request.validate(receipt: request.receipt)
        let result = try await run(reconcile ? .reconcile(request) : .mutate(request), progress: progress)
        guard let result, result.operation_id == request.operation_id,
              let outcome = result.outcome, let code = result.code,
              let cleanup = result.cleanup_pending else { throw SMBClientError.invalidResponse }
        let value = SMBMutationResult(operation_id: request.operation_id, outcome: outcome, code: code,
            entry: result.entry, sha256: result.sha256, cleanup_pending: cleanup,
            receipt: .init(staged: result.staged, archived: result.archived),
            saveContract: result.save_contract, contentEvidence: result.content_evidence)
        try value.validate(for: request, reconcile: reconcile)
        return value
    }

    @discardableResult private func run(_ operation: TransportOperation,
                     passwordOverride: String? = nil,
                     onPage: (@Sendable ([RemoteEntry]) async throws -> Void)? = nil,
                     progress: (@Sendable (Int64) -> Void)? = nil,
                     onObservedPage: (@Sendable (RemoteEntry, [RemoteEntry]) async throws -> Void)? = nil) async throws -> TransportEvent.Completion? {
        try Task.checkCancellation()
        #if MYDRIVE_DEVELOPMENT
        if AppStorage.isDevelopmentStorage { try DevelopmentConnectionScope.validate(settings) }
        #endif
        let address = try SMBAddress(server: settings.host, share: settings.share)
        let receiver = TransportReceiver(command: operation.command, uploadLimit: operation.uploadLimit, onPage: onPage, progress: progress, onObservedPage: onObservedPage)
        #if MYDRIVE_DEVELOPMENT
        let password = try passwordOverride ?? developmentPasswordOverride ?? CredentialStore.password(for: settings)
        let helperURL = try developmentHelperURL ?? AppStorage.transportURL()
        #else
        let password = try passwordOverride ?? CredentialStore.password(for: settings)
        let helperURL = try AppStorage.transportURL()
        #endif
        let input = try TransportRequest(host: address.endpoint, share: address.share,
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
    let uploadLimit: Int64?
    let onPage: (@Sendable ([RemoteEntry]) async throws -> Void)?
    let progress: (@Sendable (Int64) -> Void)?
    let onObservedPage: (@Sendable (RemoteEntry, [RemoteEntry]) async throws -> Void)?
    private var listingStart: SMBEntry?
    private var connected = false
    private var complete = false
    private var lastProgress: Int64 = 0
    private var result: TransportEvent.Completion?

    private var isDownload: Bool { command == "read" || command == "hydrate" }

    init(command: String, uploadLimit: Int64?, onPage: (@Sendable ([RemoteEntry]) async throws -> Void)?,
         progress: (@Sendable (Int64) -> Void)?,
         onObservedPage: (@Sendable (RemoteEntry, [RemoteEntry]) async throws -> Void)?) {
        self.command = command
        self.uploadLimit = uploadLimit
        self.onPage = onPage
        self.progress = progress
        self.onObservedPage = onObservedPage
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
        case "listing_started":
            guard command == "observed_list", listingStart == nil,
                  let directory = event.entry, directory.directory, directory.bytes >= 0,
                  directory.attributes & 0x10 != 0, directory.attributes & 0x400 == 0,
                  directory.objectIdentity != nil else { throw SMBClientError.invalidResponse }
            listingStart = directory
        case "page":
            guard let entries = event.entries else { throw SMBClientError.invalidResponse }
            if command == "observed_list" {
                guard let listingStart else { throw SMBClientError.invalidResponse }
                for offset in stride(from: 0, to: entries.count, by: 128) {
                    try await onObservedPage?(listingStart.observation,
                        entries[offset..<min(offset + 128, entries.count)].map(\.observation))
                }
            } else {
                guard command == "list" else { throw SMBClientError.invalidResponse }
                try await onPage?(entries.map(\.observation))
            }
        case "progress":
            guard (isDownload || command == "mutate" && uploadLimit != nil),
                  let bytes = event.bytes, bytes >= lastProgress,
                  uploadLimit.map({ bytes <= $0 }) ?? true else {
                throw SMBClientError.invalidResponse
            }
            if bytes > lastProgress {
                lastProgress = bytes
                progress?(bytes)
            }
        case "complete":
            guard let result = event.result else { throw SMBClientError.invalidResponse }
            if command == "list" || command == "observed_list" {
                guard result.complete == true else { throw SMBClientError.invalidResponse }
            }
            if command == "observed_list" {
                guard let start = listingStart, let end = result.entry, end.directory, end.bytes >= 0,
                      end.attributes & 0x10 != 0,
                      end.attributes & 0x400 == 0, end.objectIdentity == start.objectIdentity,
                      end.name.utf8.elementsEqual(start.name.utf8) else { throw SMBClientError.invalidResponse }
            }
            if isDownload {
                guard let entry = result.entry, !entry.directory, entry.bytes >= 0,
                      result.bytes == entry.bytes, entry.bytes >= lastProgress else {
                    throw SMBClientError.invalidResponse
                }
            }
            self.result = result
            complete = true
            if isDownload, let bytes = result.bytes { progress?(bytes) }
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
        case "scope_changed", "tree_scope_changed": return .scopeChanged
        case "connection_lost", "timed_out", "transport_io": return .serverUnreachable
        case "local_io": return .localFailure(message)
        case "unsupported": return .unsupportedFeature
        default: return .remoteFailure(message)
        }
    }
}

private struct BoundedEntries: Decodable {
    let values: [SMBEntry]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let count = container.count, count > 1000 { throw SMBClientError.invalidResponse }
        var values: [SMBEntry] = []
        while !container.isAtEnd {
            guard values.count < 1000 else { throw SMBClientError.invalidResponse }
            values.append(try container.decode(SMBEntry.self))
        }
        self.values = values
    }
}
