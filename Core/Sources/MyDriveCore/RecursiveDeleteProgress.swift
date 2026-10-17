import Foundation

extension Catalog {
    /// The one callback driver records verified outcomes here. Remote receipts
    /// live in the canonical child journal/plan; no scheduler or SMB wire format
    /// is introduced in Core. Removed attests permanent absence AND safe cleanup.
    @discardableResult
    public func recordRecursiveDeleteProgress(
        key: UUID, updates: [RecursiveDeleteProgress],
        advancingDomainVersion checkpoint: CatalogDomainVersionCheckpoint? = nil
    ) throws -> RecursiveDeleteStatus {
        guard updates.count <= 1_000 else { throw CatalogError.invalidPageSize }
        return try database.transaction {
            let status = try requireRecursiveStatus(key)
            var changed = false
            var retired: Set<String> = []
            var completed: [(DeleteNode, UUID)] = []
            for update in updates {
                switch update {
                case .bindOperation(let id, let childKey):
                    guard status.phase == .frozen || status.phase == .completed,
                          let node = try deleteNode(key: key, id: id) else {
                        throw CatalogError.invalidTransition
                    }
                    try requireDeleteOperation(childKey, node: node)
                    if node.removed {
                        guard node.operationKey == childKey else { throw CatalogError.idempotencyConflict }
                    } else if node.operationKey != childKey {
                        // enqueue may deduplicate an identical pre-existing
                        // normal delete. Persist its returned key before RPC.
                        guard try operation(key: node.operationKey) == nil else { throw CatalogError.idempotencyConflict }
                        try database.execute("""
                            UPDATE recursive_delete_nodes SET child_operation_key = ?
                            WHERE operation_key = ? AND item_id = ?
                            """, [.text(childKey.uuidString), .text(key.uuidString), .text(id)])
                    }
                case .blocked(let id, let code):
                    guard (1...256).contains(code.utf8.count), !code.contains("\0"),
                          let node = try deleteNode(key: key, id: id) else { throw CatalogError.invalidEntry }
                    if node.removed { continue }
                    if node.blockedCode.map({ Self.exact($0, code) }) == true { continue }
                    try database.execute("""
                        UPDATE recursive_delete_nodes SET blocked_code = ? WHERE operation_key = ? AND item_id = ?
                        """, [.text(code), .text(key.uuidString), .text(id)])
                    if node.blockedCode == nil {
                        try database.execute("UPDATE recursive_deletes SET blocked_nodes = blocked_nodes + 1 WHERE operation_key = ?",
                                             [.text(key.uuidString)])
                    }
                    changed = true
                case .removed(let id, let childKey):
                    guard status.phase == .frozen || status.phase == .completed,
                          let node = try deleteNode(key: key, id: id), node.operationKey == childKey else {
                        throw CatalogError.invalidTransition
                    }
                    if node.removed { continue }
                    let operation = try requireDeleteOperation(childKey, node: node)
                    guard operation.state == .executing || operation.state == .uncertain || operation.state == .completed,
                          try database.scalarInt("""
                            SELECT EXISTS(SELECT 1 FROM recursive_delete_nodes
                                WHERE operation_key = ? AND parent_id = ? AND removed = 0)
                            """, [.text(key.uuidString), .text(id)]) == 0 else {
                        throw CatalogError.invalidTransition
                    }
                    // A frozen pathname can become absent because its original
                    // object moved elsewhere. Never chase that Finder ID into
                    // its new namespace or tombstone a replacement identity.
                    if let live = try item(id: id), !live.isDeleted,
                       let liveParent = live.parentID, let frozenParent = node.item.parentID,
                       Self.exact(liveParent, frozenParent), Self.exact(live.entry.name, node.item.entry.name),
                       live.entry.kind == node.item.entry.kind,
                       live.entry.objectIdentity == node.item.entry.objectIdentity,
                       let livePath = try relativePath(id: id), Self.exact(livePath, node.path) {
                        try invalidateMutationScans(upserts: [], tombstones: [id])
                        try retireMutationSubtrees([id])
                        retired.insert(id)
                    }
                    try database.execute("""
                        UPDATE recursive_delete_nodes SET removed = 1, blocked_code = NULL
                        WHERE operation_key = ? AND item_id = ?
                        """, [.text(key.uuidString), .text(id)])
                    try database.execute("""
                        UPDATE recursive_deletes SET removed_nodes = removed_nodes + 1, blocked_nodes = blocked_nodes - ?
                        WHERE operation_key = ?
                        """, [.integer(node.blockedCode == nil ? 0 : 1), .text(key.uuidString)])
                    completed.append((node, childKey))
                    changed = true
                }
            }
            if !retired.isEmpty {
                try database.execute("UPDATE catalog_state SET generation = generation + 1 WHERE singleton = 1")
            }
            if changed, let checkpoint { try database.advanceDomainVersion(checkpoint) }
            let generation = try generation()
            for (node, childKey) in completed {
                if try mutationResult(key: childKey) == nil {
                    var fingerprint = MutationFingerprint()
                    fingerprint.add("mydrive-recursive-confirmed-v1"); fingerprint.add(key.uuidString)
                    fingerprint.add(node.path); fingerprint.add(node.item.entry)
                    try storeMutationResult(MutationCommitResult(items: [], tombstones: retired.contains(node.item.id) ? [node.item.id] : [],
                                                                 generation: generation),
                                            key: childKey, fingerprint: fingerprint.digest)
                }
            }
            if changed, try database.scalarInt("""
                SELECT EXISTS(SELECT 1 FROM recursive_delete_nodes WHERE operation_key = ? AND removed = 0)
                """, [.text(key.uuidString)]) == 0 {
                try database.execute("UPDATE recursive_deletes SET phase = 'completed' WHERE operation_key = ?",
                                     [.text(key.uuidString)])
                var fingerprint = MutationFingerprint()
                fingerprint.add("mydrive-recursive-root-v1"); fingerprint.add(key.uuidString)
                try storeMutationResult(MutationCommitResult(items: [], tombstones: retired.contains(status.rootID) ? [status.rootID] : [],
                                                             generation: generation),
                                        key: key, fingerprint: fingerprint.digest)
            }
            return try requireRecursiveStatus(key)
        }
    }

    @discardableResult
    private func requireDeleteOperation(_ key: UUID, node: DeleteNode) throws -> JournalOperation {
        guard let operation = try operation(key: key), case .delete = operation.intent.action,
              Self.exact(operation.intent.itemID, node.item.id),
              let path = operation.intent.sourcePath, Self.exact(path, node.path),
              let base = operation.intent.baseEntry, base.kind == node.item.entry.kind,
              Self.exact(base.name, node.item.entry.name), base.objectIdentity == node.item.entry.objectIdentity,
              node.item.entry.kind == .directory || Self.exactEntry(base, node.item.entry) else {
            throw CatalogError.idempotencyConflict
        }
        return operation
    }
}
