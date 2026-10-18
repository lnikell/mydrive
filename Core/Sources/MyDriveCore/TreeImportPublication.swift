import Foundation

extension Catalog {
    /// No array of all descendants and no child-result JSON. The immutable
    /// manifest drives one transaction; the bounded root receipt owns replay.
    func publishImport(_ record: ImportRecord, root: RemoteEntry) throws {
        let status = record.status, key = status.key
        try requireImportLayout(record)
        try requireImportChildrenComplete(key, publishKey: record.publishKey)
        try qualifyImportParent(record)
        guard status.verifiedNodes == status.tree.nodeCount,
              try database.scalarInt("SELECT count(*) FROM tree_import_nodes WHERE operation_key = ? AND verified_entry IS NOT NULL",
                                     [.text(key.uuidString)]) == status.tree.nodeCount,
              let operation = try operation(key: key), operation.intent.tree == status.tree,
              operation.state == .executing || operation.state == .uncertain else { throw CatalogError.invalidTransition }
        var tombstones: [String] = []
        if let existing = try child(named: status.filename, in: status.parentID) {
            guard existing.id != status.rootID, existing.entry.kind == .directory,
                  existing.entry.objectIdentity == root.objectIdentity else { throw CatalogError.invalidParent }
            tombstones = [existing.id]
        }
        let rootValue = CatalogMutationItem(id: status.rootID, parentID: status.parentID, entry: root)
        try invalidateMutationScans(upserts: [rootValue], tombstones: tombstones)
        if !tombstones.isEmpty { try retireMutationSubtrees(tombstones) }
        try database.statement("""
            SELECT \(Self.importNodeColumns) FROM tree_import_nodes AS node
            WHERE node.operation_key = ? ORDER BY node.depth,node.path
            """, [.text(key.uuidString)]) { row in
                while try row.step() {
                    let node = try Self.decodeImportNode(row)
                    guard let entry = node.spec.path.isEmpty ? root : node.verified else { throw CatalogError.invalidTransition }
                    if let existing = try item(id: node.itemID), !existing.isDeleted { throw CatalogError.invalidEntry }
                    let value = CatalogMutationItem(id: node.itemID, parentID: node.parentID, entry: entry)
                    try publishMutation(value)
                }
            }
        try database.execute("""
            INSERT INTO observed_directories(item_id)
            SELECT item_id FROM tree_import_nodes WHERE operation_key = ? AND kind = 'directory'
            ON CONFLICT(item_id) DO UPDATE SET is_complete=1
            """, [.text(key.uuidString)])
        try database.execute("UPDATE catalog_state SET generation = generation + 1 WHERE singleton = 1")
        guard let published = try item(id: status.rootID), !published.isDeleted else { throw CatalogError.invalidTransition }
        var fingerprint = MutationFingerprint()
        fingerprint.add("mydrive-tree-publication-v1"); fingerprint.add(status.tree.sha256)
        fingerprint.add(String(status.tree.nodeCount)); fingerprint.add(String(status.tree.totalBytes)); fingerprint.add(root)
        try storeMutationResult(.init(items: [published], tombstones: tombstones, generation: try generation()),
                                key: key, fingerprint: fingerprint.digest)
        try database.execute("UPDATE tree_imports SET phase = 'published', blocked_code = NULL WHERE operation_key = ?", [.text(key.uuidString)])
    }
}
