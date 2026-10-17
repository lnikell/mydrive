import Foundation

public struct CatalogDomainVersionState: Sendable, Equatable {
    public let epoch: Int64
    public let contextID: UUID
    public let archive: Data

    public init(epoch: Int64, contextID: UUID, archive: Data) {
        self.epoch = epoch; self.contextID = contextID; self.archive = archive
    }
}

public struct CatalogDomainVersionCheckpoint: Sendable {
    public let expectedEpoch: Int64
    public let nextArchive: Data

    public init(expectedEpoch: Int64, nextArchive: Data) {
        self.expectedEpoch = expectedEpoch; self.nextArchive = nextArchive
    }
}

extension Catalog {
    /// Native code compares the decoded opaque versions semantically. Epochs
    /// provide indexed history lookup; archive bytes are never an identity key.
    public func domainVersionState(epoch: Int64? = nil) throws -> CatalogDomainVersionState? {
        try database.domainVersionState(epoch: epoch)
    }
}

extension SQLiteConnection {
    func bootstrapDomainVersion(_ initialArchive: Data?) throws -> CatalogDomainVersionState? {
        if let initialArchive { try Self.validateDomainArchive(initialArchive) }
        return try transaction {
            if let existing = try domainVersionState() { return existing }
            guard let initialArchive else { return nil }
            try execute("INSERT INTO domain_versions(epoch,context_id,archive) VALUES(0,?,?)",
                        [.text(UUID().uuidString.lowercased()), .text(initialArchive.base64EncodedString())])
            return try domainVersionState()
        }
    }

    func domainVersionState(epoch: Int64? = nil) throws -> CatalogDomainVersionState? {
        let query = epoch == nil
            ? "SELECT epoch,context_id,archive FROM domain_versions ORDER BY epoch DESC LIMIT 1"
            : "SELECT epoch,context_id,archive FROM domain_versions WHERE epoch = ?"
        return try statement(query, epoch.map { [.integer($0)] } ?? []) { statement in
            guard try statement.step() else { return nil }
            guard let id = UUID(uuidString: statement.text(1)),
                  let archive = Data(base64Encoded: statement.text(2)) else { throw CatalogError.invalidEntry }
            try Self.validateDomainArchive(archive)
            return CatalogDomainVersionState(epoch: statement.integer(0), contextID: id, archive: archive)
        }
    }

    /// Called within the same transaction as recursive progress/publication.
    func advanceDomainVersion(_ checkpoint: CatalogDomainVersionCheckpoint) throws {
        try Self.validateDomainArchive(checkpoint.nextArchive)
        guard let current = try domainVersionState(), current.epoch == checkpoint.expectedEpoch,
              current.epoch < Int64.max else { throw CatalogError.invalidTransition }
        try execute("INSERT INTO domain_versions(epoch,context_id,archive) VALUES(?,?,?)",
                    [.integer(current.epoch + 1), .text(UUID().uuidString.lowercased()),
                     .text(checkpoint.nextArchive.base64EncodedString())])
    }

    static func validateDomainArchive(_ archive: Data) throws {
        guard (1...32_768).contains(archive.count) else { throw CatalogError.invalidEntry }
    }
}
