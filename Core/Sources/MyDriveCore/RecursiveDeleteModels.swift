import Foundation

/// Bounded namespace fence shared by every inventory operation. The selected
/// root and its parent must still be the frozen objects at these exact paths;
/// the transport compares its held handles, not separate path stat requests.
public struct RecursiveDeleteScope: Sendable, Equatable {
    public let rootPath: String
    public let rootIdentity: RemoteObjectIdentity
    public let parentPath: String
    public let parentIdentity: RemoteObjectIdentity

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootPath.utf8.elementsEqual(rhs.rootPath.utf8) && lhs.parentPath.utf8.elementsEqual(rhs.parentPath.utf8)
            && lhs.rootIdentity == rhs.rootIdentity && lhs.parentIdentity == rhs.parentIdentity
    }
}

public struct RecursiveDeleteStatus: Sendable {
    public enum Phase: String, Sendable { case building, frozen, completed }
    public let key: UUID
    public let rootID: String
    public let phase: Phase
    public let totalNodes: Int64
    public let removedNodes: Int64
    public let blockedNodes: Int64
    public let requestContext: Data?
    public let domainVersionState: CatalogDomainVersionState?
    public let scope: RecursiveDeleteScope
}

public enum RecursiveDeleteWork: Sendable {
    case capture(item: CatalogItem, path: String, scope: RecursiveDeleteScope)
    case remove(item: CatalogItem, path: String, parentIdentity: RemoteObjectIdentity, operationKey: UUID, scope: RecursiveDeleteScope)
}

/// Removed means permanent remote absence and required artifact cleanup were
/// verified, not merely a quarantine rename. The existing child journal/plan
/// remains the owner of exact transport receipts.
public enum RecursiveDeleteProgress: Sendable {
    case bindOperation(itemID: String, key: UUID)
    case removed(itemID: String, key: UUID)
    case blocked(itemID: String, code: String)
}
