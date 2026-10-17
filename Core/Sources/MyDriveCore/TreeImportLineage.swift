import Foundation

extension SQLiteConnection {
    func migrateTreeImportLayout() throws {
        try script("""
            ALTER TABLE tree_imports ADD COLUMN layout_version INTEGER NOT NULL DEFAULT 1 CHECK(layout_version IN (1,2));
            CREATE TABLE tree_import_operations(
                operation_key TEXT PRIMARY KEY REFERENCES operations(idempotency_key),
                root_key TEXT NOT NULL REFERENCES tree_imports(operation_key),
                sequence INTEGER NOT NULL UNIQUE,
                step TEXT NOT NULL CHECK(step IN ('arena','create','place','publish'))
            );
            CREATE INDEX tree_import_operation_page ON tree_import_operations(root_key,sequence);
            CREATE INDEX IF NOT EXISTS operation_items ON operations(item_id);
            """)
        // Old bindings can have been replaced by deduplication. Recover only
        // byte-exact frozen private paths, never every later edit of a live ID.
        try statement("""
            SELECT child.sequence,child.idempotency_key,child.intent,tree.operation_key,
                tree.parent_path,tree.arena_name,tree.arena_id,tree.root_id,node.scratch_path
            FROM tree_imports AS tree JOIN operations AS child
                ON child.item_id = tree.arena_id OR child.item_id = tree.root_id
            LEFT JOIN tree_import_nodes AS node ON node.operation_key = tree.operation_key AND node.item_id = child.item_id
            UNION ALL
            SELECT child.sequence,child.idempotency_key,child.intent,tree.operation_key,
                tree.parent_path,tree.arena_name,tree.arena_id,tree.root_id,node.scratch_path
            FROM tree_import_nodes AS node JOIN operations AS child ON child.item_id = node.item_id
            JOIN tree_imports AS tree ON tree.operation_key = node.operation_key
            """, []) { row in
                while try row.step() {
                    guard row.text(1) != row.text(3) else { continue }
                    let intent = try Catalog.treeDecode(JournalIntent.self, row.text(2), limit: 131_072)
                    let arena = Catalog.treeJoin(row.text(4), row.text(5))
                    let step: TreeImportStep?
                    if intent.itemID == row.text(6), intent.destinationPath.map({ Catalog.exact($0, arena) }) == true {
                        step = .arena
                    } else if intent.itemID == row.text(7),
                              intent.sourcePath.map({ Catalog.exact($0, Catalog.treeJoin(arena, "payload")) }) == true {
                        step = .publish
                    } else if let scratch = row.optionalText(8), intent.destinationPath.map({ Catalog.exact($0, scratch) }) == true {
                        step = .create
                    } else if let scratch = row.optionalText(8), intent.sourcePath.map({ Catalog.exact($0, scratch) }) == true {
                        step = .place
                    } else { step = nil }
                    guard let step else { continue }
                    if let owner = try statement("SELECT root_key,step FROM tree_import_operations WHERE operation_key = ?",
                                                 [.text(row.text(1))], { try $0.step() ? ($0.text(0), $0.text(1)) : nil }) {
                        guard owner.0 == row.text(3), owner.1 == step.rawValue else { throw CatalogError.idempotencyConflict }
                    } else {
                        try execute("INSERT INTO tree_import_operations(operation_key,root_key,sequence,step) VALUES(?,?,?,?)",
                                    [.text(row.text(1)), .text(row.text(3)), .integer(row.integer(0)), .text(step.rawValue)])
                    }
                }
            }
    }
}

extension Catalog {
    /// Every actual canonical child remains owned after a binding changes.
    /// The native owner can inspect all persisted plans before publishing.
    public func treeImportOperations(key: UUID, afterSequence: Int64? = nil,
                                     limit: Int = 128) throws -> [TreeImportOperation] {
        try Self.validatePageSize(limit)
        guard afterSequence.map({ $0 >= 0 }) ?? true else { throw CatalogError.invalidEntry }
        let record = try importRecord(key)
        try requireImportLayout(record)
        let continuation = afterSequence == nil ? "" : " AND sequence > ?"
        var values: [SQLValue] = [.text(key.uuidString)]
        if let afterSequence { values.append(.integer(afterSequence)) }
        values.append(.integer(Int64(limit)))
        return try database.statement("""
            SELECT sequence,operation_key,step FROM tree_import_operations
            WHERE root_key = ?\(continuation) ORDER BY sequence LIMIT ?
            """, values) { row in
                var page: [TreeImportOperation] = []
                while try row.step() {
                    page.append(try importOperation(record, sequence: row.integer(0), key: row.text(1), step: row.text(2)))
                }
                return page
            }
    }

    public func treeImportOperation(operationKey: UUID) throws -> TreeImportOperation? {
        try database.statement("SELECT root_key,sequence,step FROM tree_import_operations WHERE operation_key = ?",
                               [.text(operationKey.uuidString)]) { row in
            guard try row.step() else { return nil }
            guard let rootKey = UUID(uuidString: row.text(0)) else { throw CatalogError.invalidTransition }
            let record = try importRecord(rootKey)
            try requireImportLayout(record)
            return try importOperation(record, sequence: row.integer(1), key: operationKey.uuidString, step: row.text(2))
        }
    }

    private func importOperation(_ record: ImportRecord, sequence: Int64, key: String, step rawStep: String) throws -> TreeImportOperation {
        guard let operationKey = UUID(uuidString: key), let operation = try operation(key: operationKey),
              let step = TreeImportStep(rawValue: rawStep) else { throw CatalogError.invalidTransition }
        let node = step == .arena ? nil : try importNode(record.status.key, id: operation.intent.itemID)
        let work = try importMutationWork(record, step: step, node: node)
        guard case .mutation(_, let expected, let parent, let destinationParent) = work,
              Self.exact(expected.requestFingerprint, operation.intent.requestFingerprint) else {
            throw CatalogError.idempotencyConflict
        }
        return .init(sequence: sequence, operation: operation, step: step,
                     parentIdentity: parent, destinationParentIdentity: destinationParent)
    }

    func bindImportOperation(_ operation: JournalOperation, rootKey: UUID, step: TreeImportStep) throws {
        let childKey = operation.intent.idempotencyKey
        if let owner = try database.statement("SELECT root_key,step FROM tree_import_operations WHERE operation_key = ?",
                                             [.text(childKey.uuidString)], { try $0.step() ? ($0.text(0), $0.text(1)) : nil }) {
            guard owner.0 == rootKey.uuidString, owner.1 == step.rawValue else { throw CatalogError.idempotencyConflict }
            return
        }
        let sequence = try database.scalarInt("SELECT sequence FROM operations WHERE idempotency_key = ?", [.text(childKey.uuidString)])
        try database.execute("INSERT INTO tree_import_operations(operation_key,root_key,sequence,step) VALUES(?,?,?,?)",
                             [.text(childKey.uuidString), .text(rootKey.uuidString), .integer(sequence), .text(step.rawValue)])
    }

    func requireImportChildrenComplete(_ key: UUID, publishKey: UUID) throws {
        guard try database.scalarInt("""
            SELECT EXISTS(SELECT 1 FROM tree_import_operations AS history
                JOIN operations AS child ON child.idempotency_key = history.operation_key
                WHERE history.root_key = ? AND history.operation_key != ? AND child.state != 'completed')
            """, [.text(key.uuidString), .text(publishKey.uuidString)]) == 0 else { throw CatalogError.invalidTransition }
    }
}
