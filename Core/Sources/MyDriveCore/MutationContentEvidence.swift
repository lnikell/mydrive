import Foundation

/// Missing fields retain the original remotely hashed save contract on replay.
public enum MutationSaveContract: String, Codable, Sendable {
    case acknowledgedSMBV2 = "acknowledged_smb_v2"
}

/// Records the evidence used for completion, never independent cleanup authority.
public struct MutationContentEvidence: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case smbAcknowledged = "smb_acknowledged"
        case remoteSHA256 = "remote_sha256"
    }
    public let kind: Kind
    public let bytes: Int64
    public let sha256: String

    public init(kind: Kind, bytes: Int64, sha256: String) {
        self.kind = kind; self.bytes = bytes; self.sha256 = sha256
    }

    public var isValid: Bool {
        bytes >= 0 && sha256.utf8.count == 64 &&
            sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public func matches(_ payload: StagedPayload) -> Bool {
        isValid && bytes == payload.size && sha256.utf8.elementsEqual(payload.sha256.utf8)
    }

    private enum CodingKeys: String, CodingKey { case kind, bytes, sha256 }
    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        guard Set(fields.allKeys.map(\.stringValue)) == ["kind", "bytes", "sha256"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid content evidence fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        bytes = try values.decode(Int64.self, forKey: .bytes)
        sha256 = try values.decode(String.self, forKey: .sha256)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid content evidence"))
        }
    }
}

extension MutationFingerprint {
    mutating func addContentEvidence(_ evidence: MutationContentEvidence?) {
        guard let evidence else { return }
        add("contentEvidence"); add(evidence.kind.rawValue)
        add(String(evidence.bytes)); add(evidence.sha256)
    }
}

extension Catalog {
    static func validateContentEvidence(_ evidence: MutationContentEvidence?, intent: JournalIntent) throws {
        if intent.saveContract == nil {
            guard evidence == nil else { throw CatalogError.invalidEntry }
        } else {
            guard let payload = intent.payload, let evidence, evidence.matches(payload) else {
                throw CatalogError.invalidEntry
            }
        }
    }
}
