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

/// A listing observation. A remote key must be unique per directory entry across
/// the share and stable across renames/reconnects. Omit it without that guarantee,
/// including when a server reuses one object identifier for multiple hard links.
public struct RemoteEntry: Equatable, Sendable {
    public let name: String
    public let kind: ItemKind
    public let remoteKey: String?
    public let contentVersion: String
    public let metadataVersion: String
    public let size: Int64
    public let modifiedAt: Date?

    public init(
        name: String, kind: ItemKind, remoteKey: String? = nil,
        contentVersion: String, metadataVersion: String,
        size: Int64 = 0, modifiedAt: Date? = nil
    ) {
        self.name = name
        self.kind = kind
        self.remoteKey = remoteKey
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct CatalogItem: Equatable, Sendable {
    public let id: String
    public let parentID: String?
    public let entry: RemoteEntry
    public let isDeleted: Bool
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
    case rename(name: String)
    case move(parentID: String, name: String)
    case delete
}

/// Preparing an intent does not perform any remote mutation. Scheduling and
/// resolving uncertain outcomes belong to the domain coordinator.
public struct JournalIntent: Codable, Equatable, Sendable {
    public let idempotencyKey: UUID
    public let itemID: String
    public let expectedVersion: String?
    public let action: JournalAction

    public init(
        idempotencyKey: UUID = UUID(), itemID: String,
        expectedVersion: String?, action: JournalAction
    ) {
        self.idempotencyKey = idempotencyKey
        self.itemID = itemID
        self.expectedVersion = expectedVersion
        self.action = action
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
