import Foundation

extension Catalog {
    /// Qualifies a normal child delete against its immutable frozen observation,
    /// even when a refresh already retired the live Catalog row. The canonical
    /// journal's returned key and manifest binding commit together before RPC.
    public func enqueueRecursiveDeleteChild(
        key: UUID, itemID: String, intent: JournalIntent
    ) throws -> JournalOperation {
        try database.transaction {
            let status = try requireRecursiveStatus(key)
            guard status.phase == .frozen || status.phase == .completed,
                  let node = try deleteNode(key: key, id: itemID) else { throw CatalogError.invalidTransition }
            try validateDeleteIntent(intent, node: node)
            guard try node.removed || database.scalarInt("""
                SELECT EXISTS(SELECT 1 FROM recursive_delete_nodes
                    WHERE operation_key = ? AND parent_id = ? AND removed = 0)
                """, [.text(key.uuidString), .text(itemID)]) == 0 else {
                throw CatalogError.invalidTransition
            }
            let operation = try enqueueInTransaction(intent, allowRetiredDelete: true)
            try bindDeleteOperation(operation.intent.idempotencyKey, node: node, manifestKey: key)
            return operation
        }
    }

    /// Directory timestamps can change after our own child removals. Keep the
    /// immutable identity/name/kind fence; files require their full frozen base.
    func validateDeleteIntent(_ intent: JournalIntent, node: DeleteNode) throws {
        guard case .delete = intent.action, Self.exact(intent.itemID, node.item.id),
              intent.payload == nil, intent.createTemplateID == nil, intent.deletionContextID == nil,
              intent.destinationPath == nil, let path = intent.sourcePath, Self.exact(path, node.path),
              let base = intent.baseEntry, base.kind == node.item.entry.kind,
              Self.exact(base.name, node.item.entry.name), base.objectIdentity == node.item.entry.objectIdentity,
              intent.expectedVersion.map({ Self.exact($0, base.contentVersion) }) == true,
              intent.expectedMetadataVersion.map({ Self.exact($0, base.metadataVersion) }) == true,
              node.item.entry.kind == .directory || Self.exactEntry(base, node.item.entry) else {
            throw CatalogError.idempotencyConflict
        }
    }

    func bindDeleteOperation(_ childKey: UUID, node: DeleteNode, manifestKey: UUID) throws {
        guard let childOperation = try operation(key: childKey) else { throw CatalogError.invalidTransition }
        try validateDeleteIntent(childOperation.intent, node: node)
        if node.removed {
            guard node.operationKey == childKey else { throw CatalogError.idempotencyConflict }
        } else if node.operationKey != childKey {
            // Dedupe can return a pre-existing ordinary delete. Once any journal
            // owns this node's key, a changed intent cannot abandon that receipt.
            guard try operation(key: node.operationKey) == nil else { throw CatalogError.idempotencyConflict }
            try database.execute("""
                UPDATE recursive_delete_nodes SET child_operation_key = ? WHERE operation_key = ? AND item_id = ?
                """, [.text(childKey.uuidString), .text(manifestKey.uuidString), .text(node.item.id)])
        }
    }
}
