import Foundation

extension Catalog {
    /// Selects an existing deletion scope before native code qualifies a fresh
    /// request. This never creates/freezes an inventory or requires a live root.
    /// Nil and unknown contexts reuse the earliest scope; only an issued context
    /// newer than every prior fence can authorize another inventory.
    public func recursiveDeleteStatus(rootID: String, contextID: UUID?) throws -> RecursiveDeleteStatus? {
        try database.transaction(write: false) {
            let epoch = try deleteContextEpoch(contextID?.uuidString.lowercased())
            return try priorRecursiveDelete(rootID: rootID, contextEpoch: epoch)
        }
    }

    /// Starts or resumes the original immutable scope. An unknown/nil/old OS
    /// context can never expand an earlier inventory. Only a later issued native
    /// domain version authorizes another inventory for the same Finder root.
    public func prepareRecursiveDelete(
        intent: JournalIntent, rootParentIdentity: RemoteObjectIdentity, requestContext: Data? = nil
    ) throws -> RecursiveDeleteStatus {
        guard case .deleteTree = intent.action else { throw CatalogError.invalidEntry }
        if let requestContext { try SQLiteConnection.validateDomainArchive(requestContext) }
        try Self.requireDeleteIdentity(rootParentIdentity)
        return try database.transaction {
            if let existing = try operation(key: intent.idempotencyKey) {
                guard existing.intent.requestFingerprint == intent.requestFingerprint else {
                    throw CatalogError.idempotencyConflict
                }
                if let status = try recursiveStatus(key: existing.intent.idempotencyKey) { return status }
            }
            let contextEpoch = try deleteContextEpoch(intent.deletionContextID)
            if let prior = try priorRecursiveDelete(rootID: intent.itemID, contextEpoch: contextEpoch) {
                return prior
            }
            guard let root = try item(id: intent.itemID), !root.isDeleted,
                  root.entry.kind == .directory, let parentID = root.parentID,
                  let base = intent.baseEntry, let path = intent.sourcePath,
                  let actualPath = try relativePath(id: root.id), Self.exact(path, actualPath),
                  Self.exactEntry(base, root.entry) else { throw CatalogError.invalidEntry }
            try Self.validateMutationPath(path)
            try Self.requireDeleteIdentity(base.objectIdentity)
            guard path.utf8.count <= 4_096 else { throw CatalogError.invalidEntry }
            let parentPath = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
            if parentID != Self.rootID {
                guard let parent = try item(id: parentID), !parent.isDeleted,
                      parent.entry.objectIdentity == rootParentIdentity else { throw CatalogError.invalidParent }
            }
            let operation = try enqueueInTransaction(intent)
            let key = operation.intent.idempotencyKey
            guard operation.state == .queued || operation.state == .executing || operation.state == .uncertain else {
                throw CatalogError.invalidTransition
            }
            let epoch = try database.domainVersionState()?.epoch ?? -1
            try database.execute("""
                INSERT INTO recursive_deletes(operation_key,root_id,context_epoch,fence_epoch,request_context,
                    root_path,root_index,root_created,parent_path,parent_index,parent_created)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(key.uuidString), .text(root.id), contextEpoch.map(SQLValue.integer) ?? .null,
                      .integer(epoch), SQLValue(requestContext?.base64EncodedString()), .text(path),
                      .text(String(base.objectIdentity!.indexNumber)), .text(String(base.objectIdentity!.createdFiletime)),
                      .text(parentPath), .text(String(rootParentIdentity.indexNumber)), .text(String(rootParentIdentity.createdFiletime))])
            try insertDeleteNode(key: key, item: root, path: path, depth: 0, parent: rootParentIdentity)
            if operation.state == .queued {
                try database.execute("""
                    UPDATE operations SET state = 'executing', attempt_count = attempt_count + 1
                    WHERE idempotency_key = ?
                    """, [.text(key.uuidString)])
            }
            return try requireRecursiveStatus(key)
        }
    }

    /// The caller stages a complete held-directory listing through canonical
    /// beginScan/stage. Qualification, normal Catalog publication and immutable
    /// manifest capture share one transaction; an incomplete scan cannot leak a
    /// partial deletion set. A failed/interrupted directory is listed afresh.
    public func captureDeleteDirectory(
        key: UUID, scan: CatalogScan, directory: RemoteEntry
    ) throws -> RecursiveDeleteStatus {
        try database.transaction {
            let status = try requireRecursiveStatus(key)
            guard status.phase == .building, let node = try deleteNode(key: key, id: scan.parentID),
                  node.item.entry.kind == .directory else { throw CatalogError.invalidTransition }
            if node.captured { return status }
            guard directory.kind == .directory, directory.objectIdentity == node.item.entry.objectIdentity,
                  Self.exact(directory.name, node.item.entry.name),
                  let live = try item(id: node.item.id), !live.isDeleted,
                  live.entry.objectIdentity == node.item.entry.objectIdentity,
                  let livePath = try relativePath(id: live.id), Self.exact(livePath, node.path) else {
                throw CatalogError.invalidParent
            }
            // Unsupported entries stop preparation before any remote deletion.
            // Generic NAS crawling is not an atomic server snapshot; after freeze
            // the exact observed set is immutable and never grows on retry.
            let unsafe = try database.scalarInt("""
                SELECT EXISTS(SELECT 1 FROM scan_entries WHERE scan_id = ? AND
                    (kind NOT IN ('file','directory') OR object_index_number IS NULL
                     OR object_created_filetime IS NULL OR object_index_number = '0'
                     OR object_created_filetime = '0'))
                """, [.text(scan.id)])
            guard unsafe == 0 else { throw CatalogError.invalidEntry }
            _ = try completeScanInTransaction(scan)
            var added: Int64 = 0
            try database.statement("""
                SELECT \(Self.itemColumns) FROM items WHERE parent_id = ? AND is_deleted = 0 ORDER BY id
                """, [.text(node.item.id)]) { statement in
                    while try statement.step() {
                        let child = try Self.decodeItem(statement)
                        try insertDeleteNode(key: key, item: child, path: node.path + "/" + child.entry.name,
                                             depth: node.depth + 1, parent: directory.objectIdentity!)
                        added += 1
                    }
                }
            try database.execute("""
                UPDATE recursive_delete_nodes SET captured = 1 WHERE operation_key = ? AND item_id = ?;
                """, [.text(key.uuidString), .text(node.item.id)])
            try database.execute("UPDATE recursive_deletes SET total_nodes = total_nodes + ? WHERE operation_key = ?",
                                 [.integer(added), .text(key.uuidString)])
            return try requireRecursiveStatus(key)
        }
    }

    /// Indexed frontier/postorder work only. No delete work is returned until
    /// every directory listing was exhaustively captured. A frozen manifest is
    /// never rescanned to adopt concurrent new children.
    public func nextRecursiveDeleteWork(key: UUID, limit: Int = 128) throws -> [RecursiveDeleteWork] {
        try Self.validatePageSize(limit)
        return try database.transaction {
            var status = try requireRecursiveStatus(key)
            if status.phase == .completed { return [] }
            if status.phase == .building {
                let frontier = try deleteNodes(key: key, condition: "kind = 'directory' AND captured = 0", limit: limit)
                if !frontier.isEmpty { return frontier.map { .capture(item: $0.item, path: $0.path, scope: status.scope) } }
                try database.execute("UPDATE recursive_deletes SET phase = 'frozen' WHERE operation_key = ?",
                                     [.text(key.uuidString)])
                status = try requireRecursiveStatus(key)
            }
            guard status.phase == .frozen else { throw CatalogError.invalidTransition }
            return try deleteNodes(key: key, condition: """
                removed = 0 AND NOT EXISTS(
                    SELECT 1 FROM recursive_delete_nodes AS child WHERE child.operation_key = node.operation_key
                        AND child.parent_id = node.item_id AND child.removed = 0)
                """, limit: limit).map {
                    .remove(item: $0.item, path: $0.path, parentIdentity: $0.parentIdentity, operationKey: $0.operationKey, scope: status.scope)
                }
        }
    }
}
