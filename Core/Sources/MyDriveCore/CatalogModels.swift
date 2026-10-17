import Foundation

public enum CatalogError: Error, Equatable, Sendable {
    case localDatabaseRequired
    case unsupportedSchema(Int)
    case invalidName
    case invalidEntry
    case invalidPageSize
    case invalidScan
    case invalidParent
    case invalidCursor
    case staleCursor
    case missingItem(String)
    case invalidTransition
    case idempotencyConflict
    case sqlite(code: Int32, message: String)
}

public enum ItemKind: String, Codable, Sendable {
    case file, directory, symbolicLink
}

/// A server object observation, independent of opaque content/metadata versions.
/// The creation value distinguishes reused object numbers at the same pathname.
public struct RemoteObjectIdentity: Codable, Equatable, Sendable {
    public let indexNumber: UInt64
    public let createdFiletime: UInt64

    public init(indexNumber: UInt64, createdFiletime: UInt64) {
        self.indexNumber = indexNumber
        self.createdFiletime = createdFiletime
    }
}

/// A listing observation. A remote key must be unique per directory entry across
/// the share and stable across renames/reconnects. Omit it without that guarantee,
/// including when a server reuses one object identifier for multiple hard links.
public struct RemoteEntry: Codable, Equatable, Sendable {
    public let name: String
    public let kind: ItemKind
    public let remoteKey: String?
    public let contentVersion: String
    public let metadataVersion: String
    public let size: Int64
    public let modifiedAt: Date?
    public let objectIdentity: RemoteObjectIdentity?

    public init(
        name: String, kind: ItemKind, remoteKey: String? = nil,
        contentVersion: String, metadataVersion: String,
        size: Int64 = 0, modifiedAt: Date? = nil, objectIdentity: RemoteObjectIdentity? = nil
    ) {
        self.name = name
        self.kind = kind
        self.remoteKey = remoteKey
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.size = size
        self.modifiedAt = modifiedAt
        self.objectIdentity = objectIdentity
    }
}

public struct CatalogItem: Codable, Equatable, Sendable {
    public let id: String
    public let parentID: String?
    public let entry: RemoteEntry
    public let isDeleted: Bool

    public init(id: String, parentID: String?, entry: RemoteEntry, isDeleted: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.entry = entry
        self.isDeleted = isDeleted
    }
}

public enum OfflinePolicy: String, Sendable {
    case onDemand, keepAvailable
}

public enum ConnectionState: String, Sendable {
    case unknown, online, offline, authenticationRequired
}

public struct CatalogScan: Equatable, Sendable {
    public let id: String
    public let parentID: String
    let directory: CatalogItem?
    let path: String?

    init(id: String, parentID: String, directory: CatalogItem? = nil, path: String? = nil) {
        self.id = id; self.parentID = parentID
        self.directory = directory; self.path = path
    }
}

/// Valid only for one parent and one committed catalog generation. A changed
/// generation requires restarting enumeration instead of skipping/duplicating rows.
public struct ListingCursor: Codable, Equatable, Sendable {
    public let parentID: String
    public let generation: Int64
    public let lastName: String
    public let lastID: String
}

public struct CatalogPage: Sendable {
    public let items: [CatalogItem]
    public let nextCursor: ListingCursor?
    public let generation: Int64
}

public struct CatalogSettings: Equatable, Sendable {
    public let journalMode: String
    public let synchronous: Int64
    public let cacheSizeKiB: Int64
}

public enum JournalAction: Codable, Equatable, Sendable {
    case create(parentID: String, name: String, kind: ItemKind)
    case update(parentID: String, name: String)
    case rename(name: String)
    case move(parentID: String, name: String)
    case delete
    case deleteTree
}

/// Preparing an intent does not perform any remote mutation. Scheduling and
/// resolving uncertain outcomes belong to the domain coordinator.
public struct JournalIntent: Codable, Equatable, Sendable {
    public let idempotencyKey: UUID
    public let itemID: String
    public let expectedVersion: String?
    public let expectedMetadataVersion: String?
    public let action: JournalAction
    public let payload: StagedPayload?
    public let createTemplateID: String?
    public let sourcePath: String?
    public let destinationPath: String?
    public let baseEntry: RemoteEntry?
    public let deletionContextID: String?
    public let tree: StagedTreeReference?

    public init(
        idempotencyKey: UUID = UUID(), itemID: String,
        expectedVersion: String?, action: JournalAction,
        expectedMetadataVersion: String? = nil, payload: StagedPayload? = nil,
        createTemplateID: String? = nil, sourcePath: String? = nil,
        destinationPath: String? = nil, baseEntry: RemoteEntry? = nil, deletionContextID: String? = nil,
        tree: StagedTreeReference? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.itemID = itemID
        self.expectedVersion = expectedVersion
        self.expectedMetadataVersion = expectedMetadataVersion
        self.action = action
        self.payload = payload
        self.createTemplateID = createTemplateID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.baseEntry = baseEntry
        self.deletionContextID = deletionContextID
        self.tree = tree
    }
}

public enum JournalState: String, Sendable {
    case queued, executing, uncertain, completed, failed

    func permits(_ target: Self) -> Bool {
        switch (self, target) {
        case (.queued, .executing),
             (.executing, .queued), (.executing, .uncertain),
             (.executing, .completed), (.executing, .failed),
             (.uncertain, .queued), (.uncertain, .completed), (.uncertain, .failed),
             (.failed, .queued): true
        default: false
        }
    }
}

public struct JournalOperation: Equatable, Sendable {
    public let intent: JournalIntent
    public let state: JournalState
    public let attemptCount: Int64
}
