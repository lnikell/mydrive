import CryptoKit
import Foundation

/// A fully frozen local snapshot. Compression, local paths and staging UUIDs
/// do not affect semantic equality; the logical tree digest does.
public struct StagedTreeReference: Codable, Equatable, Sendable {
    public let id: UUID
    public let nodeCount: Int64
    public let totalBytes: Int64
    public let sha256: String
    public init(id: UUID, nodeCount: Int64, totalBytes: Int64, sha256: String) {
        self.id = id; self.nodeCount = nodeCount; self.totalBytes = totalBytes; self.sha256 = sha256
    }
}

public struct TreeImportEntry: Codable, Equatable, Sendable {
    /// Empty is the selected root; all other paths contain exact UTF-8 names.
    public let path: String
    public let kind: ItemKind
    public let payload: StagedPayload?
    public init(path: String, kind: ItemKind, payload: StagedPayload? = nil) {
        self.path = path; self.kind = kind; self.payload = payload
    }
}

/// Shared constant-memory framing for the local snapshot and Catalog intake.
/// Append in SQLite BINARY path order, including the empty directory root.
public struct TreeImportDigest: Sendable {
    private var hash = SHA256()
    private var lastPath: Data?
    private var count: Int64 = 0
    private var bytes: Int64 = 0
    public init() { hash.update(data: Data("mydrive-tree-v1".utf8)) }

    public mutating func append(_ entry: TreeImportEntry) throws {
        try Catalog.validateTreeEntry(entry)
        let path = Data(entry.path.utf8)
        guard lastPath.map({ $0.lexicographicallyPrecedes(path) }) ?? (entry.path.isEmpty && entry.kind == .directory) else {
            throw CatalogError.invalidEntry
        }
        let (nextCount, countOverflow) = count.addingReportingOverflow(1)
        let (nextBytes, bytesOverflow) = bytes.addingReportingOverflow(entry.payload?.size ?? 0)
        guard !countOverflow, !bytesOverflow else { throw CatalogError.invalidEntry }
        add(entry.path); add(entry.kind.rawValue)
        add(entry.payload.map { String($0.size) }); add(entry.payload?.sha256)
        lastPath = path; count = nextCount; bytes = nextBytes
    }

    public func reference(id: UUID) throws -> StagedTreeReference {
        guard count > 0 else { throw CatalogError.invalidEntry }
        return .init(id: id, nodeCount: count, totalBytes: bytes,
                     sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private mutating func add(_ value: String?) {
        guard let value else { hash.update(data: Data("-;".utf8)); return }
        hash.update(data: Data("\(value.utf8.count):".utf8)); hash.update(data: Data(value.utf8))
    }
}

public struct TreeImportScope: Sendable, Equatable {
    public let parentPath: String
    public let parentIdentity: RemoteObjectIdentity
    public let arenaName: String
    public init(parentPath: String, parentIdentity: RemoteObjectIdentity, arenaName: String) {
        self.parentPath = parentPath; self.parentIdentity = parentIdentity; self.arenaName = arenaName
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.parentPath.utf8.elementsEqual(rhs.parentPath.utf8)
            && lhs.arenaName.utf8.elementsEqual(rhs.arenaName.utf8) && lhs.parentIdentity == rhs.parentIdentity
    }
}

public enum TreeImportStep: String, Sendable { case arena, create, place, publish }

public struct TreeImportStatus: Sendable {
    public enum Phase: String, Sendable { case building, frozen, published }
    public let key: UUID
    public let tree: StagedTreeReference
    public let rootID: String
    public let parentID: String
    public let filename: String
    public let phase: Phase
    public let layoutVersion: Int
    public let scope: TreeImportScope
    public let arenaPath: String
    public let payloadPath: String
    public let destinationPath: String
    public let arena: RemoteEntry?
    public let verifiedNodes: Int64
    public let blockedCode: String?
    public let result: MutationCommitResult?
}

/// A bounded canonical-journal history page. Typed parents come from immutable
/// private observations, so cleanup does not adopt a newer live Catalog parent.
public struct TreeImportOperation: Sendable {
    public let sequence: Int64
    public let operation: JournalOperation
    public let step: TreeImportStep
    public let parentIdentity: RemoteObjectIdentity
    public let destinationParentIdentity: RemoteObjectIdentity?
}

public enum TreeImportWork: Sendable {
    case mutation(step: TreeImportStep, intent: JournalIntent, parentIdentity: RemoteObjectIdentity,
                  destinationParentIdentity: RemoteObjectIdentity?)
    case verifyFile(item: CatalogMutationItem, path: String, payload: StagedPayload)
    case verifyDirectory(item: CatalogMutationItem, path: String, scanID: UUID)
}

/// All remote success is attested by the single native callback owner. Core
/// validates the immutable intent/identity/digest and publishes no private node.
public enum TreeImportProgress: Sendable {
    case committed(step: TreeImportStep, key: UUID, entry: RemoteEntry, sha256: String?)
    case fileVerified(itemID: String, entry: RemoteEntry, sha256: String)
    case directoryPage(itemID: String, scanID: UUID, entries: [RemoteEntry])
    case directoryComplete(itemID: String, scanID: UUID, entry: RemoteEntry)
    case blocked(code: String)
}
