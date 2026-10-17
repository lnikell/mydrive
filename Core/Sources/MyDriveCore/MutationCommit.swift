import Foundation

extension Catalog {
    public func mutationResult(key: UUID) throws -> MutationCommitResult? {
        try database.statement("SELECT result FROM operations WHERE idempotency_key = ?", [.text(key.uuidString)]) {
            guard try $0.step(), let json = $0.optionalText(0) else { return nil }
            return try JSONDecoder().decode(MutationCommitResult.self, from: Data(json.utf8))
        }
    }

    /// Publishes verified observations and the completion receipt in one FULL
    /// SQLite transaction. The coordinator performs/reconciles remote work first.
    /// Tombstones name subtree roots; descendants are retired in SQL, not loaded
    /// into memory. A repeated identical commit returns its original receipt.
    @discardableResult
    public func commitMutation(
        key: UUID, upserts: [CatalogMutationItem], tombstones: [String]
    ) throws -> MutationCommitResult {
        guard upserts.count <= 1_000, tombstones.count <= 1_000,
              !upserts.isEmpty || !tombstones.isEmpty else { throw CatalogError.invalidEntry }
        let fingerprint = Self.commitFingerprint(upserts: upserts, tombstones: tombstones)
        return try database.transaction {
            guard let operation = try operation(key: key) else { throw CatalogError.invalidTransition }
            if let result = try mutationResult(key: key) {
                let original = try database.scalarText(
                    "SELECT commit_fingerprint FROM operations WHERE idempotency_key = ?", [.text(key.uuidString)])
                guard fingerprint == original else { throw CatalogError.idempotencyConflict }
                return result
            }
            guard operation.state == .executing || operation.state == .uncertain else {
                throw CatalogError.invalidTransition
            }
            let depths = try validateCommit(operation.intent, upserts: upserts, tombstones: tombstones)
            try invalidateMutationScans(upserts: upserts, tombstones: tombstones)
            let retired = Set(tombstones)
            // Release changed remote keys first, permitting an atomic identity
            // swap (for example preserving both sides of a content conflict).
            for value in upserts {
                try database.execute("UPDATE items SET remote_key = NULL WHERE id = ? AND remote_key IS NOT ?",
                                     [.text(value.id), SQLValue(value.entry.remoteKey)])
                if let remoteKey = value.entry.remoteKey {
                    try releaseRetiredKey(remoteKey, newOwner: value.id, tombstones: retired)
                }
            }
            let ordered = upserts.sorted {
                let left = depths[$0.id] ?? 0
                let right = depths[$1.id] ?? 0
                return left == right ? $0.id < $1.id : left < right
            }
            for value in ordered { try publishMutation(value) }
            try retireMutationSubtrees(tombstones)
            for value in upserts {
                let count = try database.scalarInt("""
                    SELECT count(*) FROM items WHERE parent_id = ? AND name = ? AND is_deleted = 0
                    """, [.text(value.parentID), .text(value.entry.name)])
                guard count == 1 else { throw CatalogError.invalidEntry }
            }
            try database.execute("UPDATE catalog_state SET generation = generation + 1 WHERE singleton = 1")
            let result = MutationCommitResult(
                items: try upserts.map {
                    guard let item = try item(id: $0.id), !item.isDeleted else { throw CatalogError.invalidParent }
                    return item
                }, tombstones: tombstones.sorted(), generation: try generation())
            try storeMutationResult(result, key: key, fingerprint: fingerprint)
            return result
        }
    }

    /// Shared receipt publication. Caller owns the transaction and has verified
    /// the exact intent/outcome; recursive progress never calls public commit
    /// against a mutable path reconstructed from the live Catalog.
    func storeMutationResult(_ result: MutationCommitResult, key: UUID, fingerprint: String) throws {
        let data = try JSONEncoder().encode(result)
        guard data.count <= 8_388_608 else { throw CatalogError.invalidEntry }
        try database.execute("""
            UPDATE operations SET state = 'completed', commit_fingerprint = ?, result = ? WHERE idempotency_key = ?
            """, [.text(fingerprint), .text(String(decoding: data, as: UTF8.self)), .text(key.uuidString)])
    }

    private func validateCommit(
        _ intent: JournalIntent, upserts: [CatalogMutationItem], tombstones: [String]
    ) throws -> [String: Int] {
        var proposed: [String: CatalogMutationItem] = [:]
        let retired = Set(tombstones)
        guard retired.count == tombstones.count, !retired.contains(Self.rootID) else {
            throw CatalogError.invalidEntry
        }
        for id in tombstones {
            try Self.validateMutationID(id)
            guard try item(id: id) != nil else { throw CatalogError.missingItem(id) }
        }
        for value in upserts {
            try Self.validateMutationID(value.id)
            try Self.validateMutationID(value.parentID)
            try Self.validateMutationEntry(value.entry)
            guard value.id != Self.rootID, !retired.contains(value.id),
                  proposed.updateValue(value, forKey: value.id) == nil else { throw CatalogError.invalidEntry }
            if let old = try item(id: value.id), old.entry.kind != value.entry.kind {
                throw CatalogError.invalidEntry // A different kind requires a new Finder identity.
            }
        }
        switch intent.action {
        case .delete:
            guard retired.contains(intent.itemID) else { throw CatalogError.invalidEntry }
        case .deleteTree:
            throw CatalogError.invalidTransition // Only verified manifest progress can complete this root.
        default:
            guard proposed[intent.itemID] != nil else { throw CatalogError.invalidEntry }
        }
        if let payload = intent.payload {
            guard let result = proposed[intent.itemID], result.entry.kind == .file,
                  result.entry.size == payload.size else { throw CatalogError.invalidEntry }
        }
        var depths: [String: Int] = [:]
        for value in upserts {
            depths[value.id] = try mutationDepth(of: value, proposed: proposed, retired: retired)
        }
        return depths
    }

    /// Validate the resulting ancestry, including other upserts. This accepts a
    /// child moved out of a deleted subtree but rejects cycles and orphan trees.
    private func mutationDepth(
        of value: CatalogMutationItem, proposed: [String: CatalogMutationItem], retired: Set<String> = []
    ) throws -> Int {
        var seen: Set<String> = [value.id]
        var parentID = value.parentID
        var depth = 0
        while parentID != Self.rootID {
            guard depth < 1_024, !retired.contains(parentID), seen.insert(parentID).inserted else {
                throw CatalogError.invalidParent
            }
            if let parent = proposed[parentID] {
                guard parent.entry.kind == .directory else { throw CatalogError.invalidParent }
                parentID = parent.parentID
            } else {
                guard let parent = try item(id: parentID), !parent.isDeleted,
                      parent.entry.kind == .directory, let ancestor = parent.parentID else {
                    throw CatalogError.invalidParent
                }
                parentID = ancestor
            }
            depth += 1
        }
        return depth
    }

    private func releaseRetiredKey(_ key: String, newOwner: String, tombstones: Set<String>) throws {
        let owner = try database.statement("SELECT id FROM items WHERE remote_key = ?", [.text(key)]) {
            try $0.step() ? $0.text(0) : nil
        }
        guard let owner, owner != newOwner, tombstones.contains(owner) else { return }
        try database.execute("UPDATE items SET remote_key = NULL WHERE id = ?", [.text(owner)])
    }

    private func publishMutation(_ value: CatalogMutationItem) throws {
        let entry = value.entry
        try database.execute("""
            INSERT INTO items(id, parent_id, name, kind, remote_key, content_version, metadata_version,
                              size, modified_at, is_deleted, object_index_number, object_created_filetime)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
            ON CONFLICT(id) DO UPDATE SET parent_id = excluded.parent_id, name = excluded.name,
                kind = excluded.kind, remote_key = excluded.remote_key, content_version = excluded.content_version,
                metadata_version = excluded.metadata_version, size = excluded.size,
                modified_at = excluded.modified_at, is_deleted = 0,
                object_index_number = excluded.object_index_number,
                object_created_filetime = excluded.object_created_filetime
            """, [.text(value.id), .text(value.parentID), .text(entry.name), .text(entry.kind.rawValue),
                  SQLValue(entry.remoteKey), .text(entry.contentVersion), .text(entry.metadataVersion),
                  .integer(entry.size), SQLValue(entry.modifiedAt),
                  SQLValue(entry.objectIdentity.map { String($0.indexNumber) }),
                  SQLValue(entry.objectIdentity.map { String($0.createdFiletime) })])
    }

    func invalidateMutationScans(upserts: [CatalogMutationItem], tombstones: [String]) throws {
        var parents = Set(upserts.map(\.parentID))
        var directories = Set(upserts.filter { $0.entry.kind == .directory }.map(\.id))
        for id in upserts.map(\.id) + tombstones {
            if let old = try item(id: id) {
                if let parent = old.parentID { parents.insert(parent) }
                if old.entry.kind == .directory { directories.insert(id) }
            }
        }
        if !parents.isEmpty {
            let placeholders = Array(repeating: "?", count: parents.count).joined(separator: ",")
            try database.execute("DELETE FROM scans WHERE parent_id IN (\(placeholders))", parents.map(SQLValue.text))
        }
        guard !directories.isEmpty else { return }
        // Walk the few active scans' ancestors, rather than every item in a
        // potentially enormous renamed directory. A former-path listing cannot
        // undo a newer verified mutation when its network request returns late.
        let placeholders = Array(repeating: "?", count: directories.count).joined(separator: ",")
        try database.execute("""
            WITH RECURSIVE ancestors(scan_id, item_id, depth) AS (
                SELECT id, parent_id, 0 FROM scans
                UNION ALL
                SELECT ancestors.scan_id, items.parent_id, ancestors.depth + 1
                FROM ancestors JOIN items ON items.id = ancestors.item_id
                WHERE items.parent_id IS NOT NULL AND ancestors.depth < 1024
            )
            DELETE FROM scans WHERE id IN (
                SELECT scan_id FROM ancestors WHERE item_id IN (\(placeholders))
            )
            """, directories.map(SQLValue.text))
    }

    func retireMutationSubtrees(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try database.execute("""
            WITH RECURSIVE retired(id) AS (
                SELECT id FROM items WHERE id IN (\(placeholders))
                UNION SELECT items.id FROM items JOIN retired ON items.parent_id = retired.id WHERE items.is_deleted = 0
            )
            UPDATE items SET is_deleted = 1 WHERE id IN (SELECT id FROM retired) AND is_deleted = 0
            """, ids.map(SQLValue.text))
    }

    private static func commitFingerprint(upserts: [CatalogMutationItem], tombstones: [String]) -> String {
        var fields = MutationFingerprint()
        fields.add("mydrive-commit-v1"); fields.add(String(upserts.count))
        for value in upserts.sorted(by: { $0.id < $1.id }) {
            fields.add(value.id); fields.add(value.parentID); fields.add(value.entry)
        }
        fields.add(String(tombstones.count))
        for id in tombstones.sorted() { fields.add(id) }
        return fields.digest
    }
}
