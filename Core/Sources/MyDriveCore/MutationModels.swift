import CryptoKit
import Foundation

/// Immutable bytes owned by the provider's durable staging directory. The UUID
/// is a reference, never an arbitrary path; Catalog stores no file contents.
public struct StagedPayload: Codable, Equatable, Sendable {
    public let id: UUID
    public let size: Int64
    public let sha256: String

    public init(id: UUID, size: Int64, sha256: String) {
        self.id = id
        self.size = size
        self.sha256 = sha256
    }
}

/// An independently verified remote result, published under the exact Finder ID.
public struct CatalogMutationItem: Codable, Equatable, Sendable {
    public let id: String
    public let parentID: String
    public let entry: RemoteEntry

    public init(id: String, parentID: String, entry: RemoteEntry) {
        self.id = id
        self.parentID = parentID
        self.entry = entry
    }
}

/// A durable receipt. Replaying a completed callback returns these original
/// observations, even after a subsequent remote scan changes the live Catalog.
public struct MutationCommitResult: Codable, Equatable, Sendable {
    public let items: [CatalogItem]
    public let tombstones: [String]
    public let generation: Int64
}

extension JournalIntent {
    /// Stable across processes and retransmission. A fresh staging UUID for the
    /// same bytes does not create another remote write. Callers must use the
    /// operation returned by enqueue, including its original key/payload UUID.
    public var requestFingerprint: String {
        var fields = MutationFingerprint()
        fields.add("mydrive-mutation-v1")
        fields.add(itemID)
        fields.add(expectedVersion)
        fields.add(expectedMetadataVersion)
        switch action {
        case .create(let parentID, let name, let kind):
            fields.add("create"); fields.add(parentID); fields.add(name); fields.add(kind.rawValue)
        case .update(let parentID, let name):
            fields.add("update"); fields.add(parentID); fields.add(name)
        case .rename(let name): fields.add("rename"); fields.add(name)
        case .move(let parentID, let name): fields.add("move"); fields.add(parentID); fields.add(name)
        case .delete: fields.add("delete")
        case .deleteTree: fields.add("deleteTree")
        }
        fields.add(payload.map { String($0.size) })
        fields.add(payload?.sha256)
        fields.add(createTemplateID)
        fields.add(sourcePath)
        fields.add(destinationPath)
        fields.add(baseEntry)
        if let deletionContextID { fields.add("deletionContext"); fields.add(deletionContextID) }
        if let tree {
            fields.add("tree-v1"); fields.add(String(tree.nodeCount))
            fields.add(String(tree.totalBytes)); fields.add(tree.sha256)
        }
        return fields.digest
    }
}

/// Length-prefixed UTF-8 preserves exact Unicode spelling without delimiter
/// ambiguity, locale dependence or Swift's randomized Hasher.
struct MutationFingerprint {
    private var bytes = Data()

    mutating func add(_ value: String?) {
        guard let value else { bytes.append(contentsOf: "-;".utf8); return }
        bytes.append(contentsOf: "\(value.utf8.count):".utf8)
        bytes.append(contentsOf: value.utf8)
    }

    mutating func add(_ entry: RemoteEntry?) {
        add(entry == nil ? nil : "entry")
        guard let entry else { return }
        add(entry.name); add(entry.kind.rawValue); add(entry.remoteKey)
        add(entry.contentVersion); add(entry.metadataVersion); add(String(entry.size))
        add(entry.modifiedAt.map { String($0.timeIntervalSince1970.bitPattern) })
        // Leave the legacy nil encoding unchanged for already-durable intents.
        if let identity = entry.objectIdentity {
            add("objectIdentity"); add(String(identity.indexNumber)); add(String(identity.createdFiletime))
        }
    }

    var digest: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
