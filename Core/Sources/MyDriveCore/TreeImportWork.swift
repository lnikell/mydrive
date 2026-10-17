import Foundation

extension Catalog {
    /// Indexed private frontier, then postorder verification. This does not run
    /// I/O or a second scheduler. A caller must bind each returned mutation to
    /// the canonical journal before invoking its saved transport plan.
    public func nextTreeImportWork(key: UUID, limit: Int = 128) throws -> [TreeImportWork] {
        try Self.validatePageSize(limit)
        return try database.transaction {
            let record = try importRecord(key), status = record.status
            if status.phase == .published { return [] }
            guard status.phase == .frozen else { throw CatalogError.invalidTransition }
            try qualifyImportParent(record)
            guard let arena = status.arena else { return [try importMutationWork(record, step: .arena)] }
            let pending = try database.statement("""
                SELECT \(Self.importNodeColumns) FROM tree_import_nodes AS node
                WHERE node.operation_key = ? AND node.placed_entry IS NULL AND (node.path = '' OR EXISTS(
                    SELECT 1 FROM tree_import_nodes AS parent WHERE parent.operation_key = node.operation_key
                        AND parent.path = node.parent_path AND parent.placed_entry IS NOT NULL))
                ORDER BY node.depth,node.path LIMIT ?
                """, [.text(key.uuidString), .integer(Int64(limit))]) { row in
                    var result: [ImportNode] = []
                    while try row.step() { result.append(try Self.decodeImportNode(row)) }
                    return result
                }
            if !pending.isEmpty {
                return try pending.map { try importMutationWork(record, step: $0.created == nil ? .create : .place, node: $0) }
            }
            let unverified = try database.statement("""
                SELECT \(Self.importNodeColumns) FROM tree_import_nodes AS node
                WHERE node.operation_key = ? AND node.verified_entry IS NULL AND NOT EXISTS(
                    SELECT 1 FROM tree_import_nodes AS child WHERE child.operation_key = node.operation_key
                        AND child.parent_path = node.path AND child.verified_entry IS NULL)
                ORDER BY node.depth DESC,node.path LIMIT ?
                """, [.text(key.uuidString), .integer(Int64(limit))]) { row in
                    var result: [ImportNode] = []
                    while try row.step() { result.append(try Self.decodeImportNode(row)) }
                    return result
                }
            if !unverified.isEmpty {
                return try unverified.map { node in
                    guard let entry = node.placed else { throw CatalogError.invalidTransition }
                    let path = node.spec.path.isEmpty ? status.payloadPath : Self.treeJoin(status.payloadPath, node.spec.path)
                    if let payload = node.spec.payload { return .verifyFile(item: node.item(entry), path: path, payload: payload) }
                    let scan = UUID()
                    try database.execute("UPDATE tree_import_nodes SET verification_scan = ? WHERE operation_key = ? AND path = ?",
                                         [.text(scan.uuidString), .text(key.uuidString), .text(node.spec.path)])
                    return .verifyDirectory(item: node.item(entry), path: path, scanID: scan)
                }
            }
            guard arena.objectIdentity != nil, let root = try importNode(key, path: ""), root.verified != nil else {
                throw CatalogError.invalidTransition
            }
            return [try importMutationWork(record, step: .publish, node: root)]
        }
    }

    /// Private parents are qualified only through this sealed manifest. Generic
    /// enqueue/commit cannot manufacture live Catalog rows for scratch objects.
    public func enqueueTreeImportChild(key: UUID, step: TreeImportStep, intent: JournalIntent) throws -> JournalOperation {
        try database.transaction {
            let record = try importRecord(key)
            guard record.status.phase == .frozen else { throw CatalogError.invalidTransition }
            try qualifyImportParent(record)
            let node = step == .arena ? nil : try importNode(key, id: intent.itemID)
            let work = try importMutationWork(record, step: step, node: node)
            guard case .mutation(_, let expected, _, _) = work,
                  Self.exact(expected.requestFingerprint, intent.requestFingerprint),
                  expected.idempotencyKey == intent.idempotencyKey else { throw CatalogError.idempotencyConflict }
            let operation = try matchingOperation(intent) ?? insertQualifiedOperation(intent)
            let childKey = operation.intent.idempotencyKey
            if childKey != expected.idempotencyKey {
                switch step {
                case .arena, .publish:
                    let column = step == .arena ? "arena_operation_key" : "publish_operation_key"
                    try database.execute("UPDATE tree_imports SET \(column) = ? WHERE operation_key = ?",
                                         [.text(childKey.uuidString), .text(key.uuidString)])
                case .create, .place:
                    let column = step == .create ? "create_operation_key" : "place_operation_key"
                    try database.execute("UPDATE tree_import_nodes SET \(column) = ? WHERE operation_key = ? AND item_id = ?",
                                         [.text(childKey.uuidString), .text(key.uuidString), .text(intent.itemID)])
                }
            }
            if let root = try self.operation(key: key), root.state == .queued {
                try database.execute("UPDATE operations SET state = 'executing', attempt_count = attempt_count + 1 WHERE idempotency_key = ?",
                                     [.text(key.uuidString)])
            }
            return operation
        }
    }

    func importMutationWork(_ record: ImportRecord, step: TreeImportStep, node: ImportNode? = nil) throws -> TreeImportWork {
        let status = record.status
        if step == .arena {
            let intent = JournalIntent(idempotencyKey: record.arenaKey, itemID: record.arenaID, expectedVersion: nil,
                action: .create(parentID: status.parentID, name: status.scope.arenaName, kind: .directory),
                destinationPath: status.arenaPath)
            return .mutation(step: step, intent: intent, parentIdentity: status.scope.parentIdentity, destinationParentIdentity: nil)
        }
        guard let arenaIdentity = status.arena?.objectIdentity, let node else { throw CatalogError.invalidTransition }
        let payloadPath = node.spec.path.isEmpty ? status.payloadPath : Self.treeJoin(status.payloadPath, node.spec.path)
        if step == .create {
            if let parent = node.parentPath {
                guard try importNode(status.key, path: parent)?.placed != nil else { throw CatalogError.invalidTransition }
            }
            let intent = JournalIntent(idempotencyKey: node.createKey, itemID: node.itemID, expectedVersion: nil,
                action: .create(parentID: record.arenaID, name: Self.treeName(node.scratchPath), kind: node.spec.kind),
                payload: node.spec.payload, destinationPath: node.scratchPath)
            return .mutation(step: step, intent: intent, parentIdentity: arenaIdentity, destinationParentIdentity: nil)
        }
        if step == .place {
            guard let created = node.created else { throw CatalogError.invalidTransition }
            let destinationParent: RemoteObjectIdentity
            let parentID: String
            if let parentPath = node.parentPath {
                guard let parent = try importNode(status.key, path: parentPath), let identity = parent.placed?.objectIdentity else {
                    throw CatalogError.invalidTransition
                }
                destinationParent = identity; parentID = parent.itemID
            } else { destinationParent = arenaIdentity; parentID = record.arenaID }
            let intent = JournalIntent(idempotencyKey: node.placeKey, itemID: node.itemID,
                expectedVersion: created.contentVersion, action: .move(parentID: parentID, name: Self.treeName(payloadPath)),
                expectedMetadataVersion: created.metadataVersion, sourcePath: node.scratchPath,
                destinationPath: payloadPath, baseEntry: created)
            return .mutation(step: step, intent: intent, parentIdentity: arenaIdentity, destinationParentIdentity: destinationParent)
        }
        guard step == .publish, node.spec.path.isEmpty, let entry = node.verified,
              status.verifiedNodes == status.tree.nodeCount else { throw CatalogError.invalidTransition }
        let intent = JournalIntent(idempotencyKey: record.publishKey, itemID: status.rootID,
            expectedVersion: entry.contentVersion, action: .move(parentID: status.parentID, name: status.filename),
            expectedMetadataVersion: entry.metadataVersion, sourcePath: status.payloadPath,
            destinationPath: status.destinationPath, baseEntry: entry)
        return .mutation(step: step, intent: intent, parentIdentity: arenaIdentity, destinationParentIdentity: status.scope.parentIdentity)
    }
}
