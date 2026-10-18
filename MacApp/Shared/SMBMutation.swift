import Foundation
import MyDriveCore

/// Fixed selection fences; the transport reserves and compares both objects.
struct SMBDeleteScope: Codable, Equatable, Sendable {
    let root_path: String
    let root: SMBMutationRequest.ParentIdentity
    let parent: SMBMutationRequest.ParentIdentity

    init(_ value: RecursiveDeleteScope) {
        root_path = value.rootPath; root = .init(value.rootIdentity); parent = .init(value.parentIdentity)
    }

    func contains(_ path: String) -> Bool {
        path.utf8.elementsEqual(root_path.utf8) || path.utf8.starts(with: (root_path + "/").utf8)
    }

    static func == (left: Self, right: Self) -> Bool {
        left.root_path.utf8.elementsEqual(right.root_path.utf8) && left.root == right.root && left.parent == right.parent
    }
}

/// Layout 2: the arena is the future payload root. Every child is born in
/// its intended staged parent and final publication is a same-parent rename.
struct SMBTreeScope: Codable, Equatable, Sendable {
    let layout_version: Int
    let arena_path: String
    let arena: SMBMutationRequest.ParentIdentity
    let parent: SMBMutationRequest.ParentIdentity

    init(arena_path: String, arena: SMBMutationRequest.ParentIdentity, parent: SMBMutationRequest.ParentIdentity) {
        layout_version = 2; self.arena_path = arena_path; self.arena = arena; self.parent = parent
    }
    private enum CodingKeys: String, CodingKey { case layout_version, arena_path, arena, parent }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layout_version = try values.decode(Int.self, forKey: .layout_version)
        guard layout_version == 2 else { throw DecodingError.dataCorruptedError(forKey: .layout_version, in: values,
            debugDescription: "Unsupported private tree layout") }
        arena_path = try values.decode(String.self, forKey: .arena_path)
        arena = try values.decode(SMBMutationRequest.ParentIdentity.self, forKey: .arena)
        parent = try values.decode(SMBMutationRequest.ParentIdentity.self, forKey: .parent)
    }
    var isValid: Bool { layout_version == 2 && !arena_path.isEmpty && arena.isValid && parent.isValid }
    func contains(_ path: String) -> Bool {
        path.utf8.elementsEqual(arena_path.utf8) || path.utf8.starts(with: (arena_path + "/").utf8)
    }
    func containsPayload(_ path: String) -> Bool { contains(path) }
    static func == (left: Self, right: Self) -> Bool {
        left.layout_version == right.layout_version && left.arena_path.utf8.elementsEqual(right.arena_path.utf8) &&
            left.arena == right.arena && left.parent == right.parent
    }
}

/// Nonsecret, immutable wire intent. The provider persists this exact record
/// before an RPC; credentials are added only by SMBClient for that invocation.
struct SMBMutationRequest: Codable, Equatable, Sendable {
    struct ParentIdentity: Codable, Equatable, Sendable {
        let index_number: UInt64
        let created_filetime: UInt64

        init(_ identity: RemoteObjectIdentity) {
            index_number = identity.indexNumber
            created_filetime = identity.createdFiletime
        }

        var isValid: Bool { index_number != 0 && created_filetime != 0 }
    }
    enum Kind: String, Codable, Sendable {
        case createFile = "create_file", createDirectory = "create_directory"
        case replaceFile = "replace_file", move, delete, cleanup
    }
    struct Payload: Codable, Equatable, Sendable {
        let source: String
        let bytes: Int64
        let sha256: String
    }
    struct Artifact: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable { case allocated, prepared }
        let path: String
        let entry: SMBEntry
        let cleanup_safe: Bool
        let phase: Phase
        let security_sha256: String?
        let save_contract: MutationSaveContract?
        private enum CodingKeys: String, CodingKey { case path, entry, cleanup_safe, phase, security_sha256, save_contract }
        init(path: String, entry: SMBEntry, cleanup_safe: Bool, phase: Phase = .prepared, security_sha256: String? = nil,
             saveContract: MutationSaveContract? = nil) {
            self.path = path; self.entry = entry; self.cleanup_safe = cleanup_safe
            self.phase = phase; self.security_sha256 = security_sha256
            save_contract = saveContract
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            entry = try values.decode(SMBEntry.self, forKey: .entry)
            cleanup_safe = try values.decodeIfPresent(Bool.self, forKey: .cleanup_safe) ?? false
            phase = try values.decodeIfPresent(Phase.self, forKey: .phase) ?? .prepared
            security_sha256 = try values.decodeIfPresent(String.self, forKey: .security_sha256)
            save_contract = try values.decodeIfPresent(MutationSaveContract.self, forKey: .save_contract)
        }
    }
    struct Receipt: Codable, Equatable, Sendable {
        var staged: Artifact?
        var archived: Artifact?
        init(staged: Artifact? = nil, archived: Artifact? = nil) {
            self.staged = staged; self.archived = archived
        }
    }
    let operation_id: String
    let kind: Kind
    let path: String
    let parent: ParentIdentity
    let destination: String?
    let destination_parent: ParentIdentity?
    let expected: SMBEntry?
    let payload: Payload?
    let delete_scope: SMBDeleteScope?
    let tree_scope: SMBTreeScope?
    let save_contract: MutationSaveContract?
    var receipt: Receipt

    init(operationID: UUID, kind: Kind, path: String, parent: ParentIdentity,
         destination: String? = nil, destinationParent: ParentIdentity? = nil,
         expected: SMBEntry? = nil, payload: Payload? = nil, receipt: Receipt = Receipt(),
         deleteScope: SMBDeleteScope? = nil, treeScope: SMBTreeScope? = nil,
         saveContract: MutationSaveContract? = nil) {
        operation_id = operationID.uuidString.lowercased()
        self.kind = kind; self.path = path; self.parent = parent
        self.destination = destination; destination_parent = destinationParent
        self.expected = expected; self.payload = payload; self.receipt = receipt
        delete_scope = deleteScope
        tree_scope = treeScope
        save_contract = saveContract
    }

    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func sidecar(_ suffix: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return (components.dropLast().map(String.init) + [".mydrive-\(operation_id).\(suffix)"]).joined(separator: "/")
    }

    func validate(receipt: Receipt) throws {
        if save_contract != nil {
            guard [.createFile, .replaceFile].contains(kind), let payload,
                  payload.bytes >= 0, Self.validHash(payload.sha256), expected?.directory != true else {
                throw SMBClientError.invalidResponse
            }
        }
        if let staged = receipt.staged {
            guard staged.path.utf8.elementsEqual(sidecar("stage").utf8), staged.entry.bytes >= 0,
                  staged.save_contract == save_contract,
                  save_contract == nil || staged.phase == .allocated,
                  staged.entry.index_number != nil, staged.entry.index_number != 0, staged.entry.created_filetime != 0 else {
                throw SMBClientError.invalidResponse
            }
            if staged.phase == .allocated {
                guard [.createFile, .replaceFile].contains(kind), payload != nil,
                      let security = staged.security_sha256, Self.validHash(security),
                      staged.entry.bytes == 0, !staged.entry.directory, staged.cleanup_safe else {
                    throw SMBClientError.invalidResponse
                }
            }
        }
        if let archived = receipt.archived {
            guard archived.path.utf8.elementsEqual(sidecar(kind == .delete ? "deleted" : "backup").utf8),
                  archived.save_contract == nil,
                  archived.entry.bytes >= 0,
                  archived.entry.index_number != nil, archived.entry.index_number != 0, archived.entry.created_filetime != 0 else { throw SMBClientError.invalidResponse }
        }
    }
}

struct SMBMutationResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case committed, notApplied = "not_applied", conflict, uncertain }
    let operation_id: String
    let outcome: Outcome
    let code: String
    let entry: SMBEntry?
    let sha256: String?
    let cleanup_pending: Bool
    let receipt: SMBMutationRequest.Receipt
    let save_contract: MutationSaveContract?
    let content_evidence: MutationContentEvidence?

    init(operation_id: String, outcome: Outcome, code: String, entry: SMBEntry?, sha256: String?,
         cleanup_pending: Bool, receipt: SMBMutationRequest.Receipt,
         saveContract: MutationSaveContract? = nil, contentEvidence: MutationContentEvidence? = nil) {
        self.operation_id = operation_id; self.outcome = outcome; self.code = code
        self.entry = entry; self.sha256 = sha256; self.cleanup_pending = cleanup_pending; self.receipt = receipt
        save_contract = saveContract; content_evidence = contentEvidence
    }

    /// The same validation applies to fresh frames and saved results. A nil
    /// invocation role validates stored facts without making them live proof.
    func validate(for request: SMBMutationRequest, reconcile: Bool? = nil) throws {
        guard operation_id == request.operation_id, entry.map({ $0.bytes >= 0 }) ?? true else {
            throw SMBClientError.invalidResponse
        }
        try request.validate(receipt: request.receipt)
        try request.validate(receipt: receipt)
        if request.save_contract != nil {
            guard save_contract == request.save_contract, sha256 == nil, code != "prepared" else {
                throw SMBClientError.invalidResponse
            }
            if outcome == .committed {
                guard receipt.staged == nil, let payload = request.payload, let evidence = content_evidence, evidence.isValid,
                      evidence.bytes == payload.bytes, evidence.sha256 == payload.sha256,
                      let creator = request.receipt.staged?.entry.objectIdentity,
                      entry?.objectIdentity == creator,
                      reconcile != true || evidence.kind == .remoteSHA256,
                      reconcile != false || evidence.kind == .smbAcknowledged else {
                    throw SMBClientError.invalidResponse
                }
            } else if content_evidence != nil { throw SMBClientError.invalidResponse }
        } else {
            guard save_contract == nil, content_evidence == nil else { throw SMBClientError.invalidResponse }
            if let sha256, !SMBMutationRequest.validHash(sha256) { throw SMBClientError.invalidResponse }
        }
        if outcome == .committed {
            if [.createFile, .createDirectory, .replaceFile, .move].contains(request.kind) {
                let target = request.destination ?? request.path
                guard let entry, let name = target.split(separator: "/").last,
                      entry.name.utf8.elementsEqual(name.utf8),
                      entry.directory == (request.kind == .createDirectory || request.expected?.directory == true) else {
                    throw SMBClientError.invalidResponse
                }
            }
            if let payload = request.payload {
                guard entry?.bytes == payload.bytes,
                      request.save_contract != nil || sha256 == payload.sha256 else { throw SMBClientError.invalidResponse }
            }
        }
        if code == "allocation_unknown" {
            guard outcome == .uncertain, request.receipt.staged == nil, receipt.staged == nil,
                  request.receipt.archived.map({ receipt.archived == $0 }) ?? true else { throw SMBClientError.invalidResponse }
        }
        if outcome == .notApplied && code == "allocated" {
            guard receipt.staged?.phase == .allocated, receipt.archived == nil else { throw SMBClientError.invalidResponse }
        }
        if outcome == .notApplied && code == "prepared" {
            guard let staged = receipt.staged, staged.phase == .prepared,
                  request.payload.map({ staged.entry.bytes == $0.bytes }) ?? staged.entry.directory else {
                throw SMBClientError.invalidResponse
            }
        }
    }
}
