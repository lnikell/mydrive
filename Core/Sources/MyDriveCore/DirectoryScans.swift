import Foundation

extension Catalog {
    /// Starts a new observation without touching published children. A new scan
    /// supersedes an interrupted scan for this parent, never the previous listing.
    public func beginScan(of parentID: String = Catalog.rootID) throws -> CatalogScan {
        try database.transaction {
            try requireDirectory(parentID)
            try database.execute("DELETE FROM scans WHERE parent_id = ?", [.text(parentID)])
            let scan = CatalogScan(id: UUID().uuidString, parentID: parentID)
            try database.execute("INSERT INTO scans(id, parent_id) VALUES (?, ?)", [.text(scan.id), .text(parentID)])
            return scan
        }
    }

    /// The transport submits bounded pages. Duplicate names/remote keys fail the
    /// entire submitted batch; a malformed observation cannot partially publish.
    public func stage(_ entries: [RemoteEntry], in scan: CatalogScan) throws {
        guard entries.count <= 1_000 else { throw CatalogError.invalidPageSize }
        for entry in entries {
            try Self.validateName(entry.name)
            guard entry.size >= 0, entry.remoteKey != "" else { throw CatalogError.invalidEntry }
        }
        try database.transaction {
            try requireScan(scan)
            try database.statement("""
                INSERT INTO scan_entries(
                    scan_id, name, kind, remote_key, content_version, metadata_version, size, modified_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """) { statement in
                for entry in entries {
                    try statement.bind([
                        .text(scan.id), .text(entry.name), .text(entry.kind.rawValue), SQLValue(entry.remoteKey),
                        .text(entry.contentVersion), .text(entry.metadataVersion), .integer(entry.size),
                        SQLValue(entry.modifiedAt)])
                    _ = try statement.step()
                    try statement.reset()
                }
            }
        }
    }

    /// Call only after the transport confirms an exhaustive successful listing.
    /// Publication, disappearances and stable-identity updates commit atomically.
    /// Without a stable remote key, identity is preserved only at the same path.
    @discardableResult
    public func completeScan(_ scan: CatalogScan) throws -> Int64 {
        try database.transaction {
            try requireScan(scan)
            try requireDirectory(scan.parentID)
            try database.execute("""
                UPDATE scan_entries SET item_id = COALESCE(
                    CASE WHEN remote_key IS NOT NULL
                        THEN (SELECT id FROM items WHERE items.remote_key = scan_entries.remote_key)
                        ELSE (SELECT id FROM items WHERE parent_id = ? AND name = scan_entries.name
                              AND kind = scan_entries.kind AND is_deleted = 0)
                    END,
                    lower(hex(randomblob(16))))
                WHERE scan_id = ?
                """, [.text(scan.parentID), .text(scan.id)])
            try validateNoAncestorReuse(scan)
            try database.execute("INSERT OR IGNORE INTO observed_directories(item_id) VALUES (?)", [.text(scan.parentID)])
            if try !hasChanges(scan) {
                try database.execute("DELETE FROM scans WHERE id = ?", [.text(scan.id)])
                return try database.scalarInt("SELECT generation FROM catalog_state WHERE singleton = 1")
            }
            try database.execute("""
                WITH RECURSIVE missing(id) AS (
                    SELECT id FROM items WHERE parent_id = ? AND is_deleted = 0
                        AND id NOT IN (SELECT item_id FROM scan_entries WHERE scan_id = ?)
                    UNION
                    SELECT items.id FROM items JOIN missing ON items.parent_id = missing.id
                    WHERE items.is_deleted = 0
                        AND items.id NOT IN (SELECT item_id FROM scan_entries WHERE scan_id = ?)
                )
                UPDATE items SET is_deleted = 1 WHERE id IN (SELECT id FROM missing)
                """, [.text(scan.parentID), .text(scan.id), .text(scan.id)])
            try database.execute("""
                INSERT INTO items(
                    id, parent_id, name, kind, remote_key, content_version, metadata_version, size, modified_at, is_deleted)
                SELECT item_id, ?, name, kind, remote_key, content_version, metadata_version, size, modified_at, 0
                FROM scan_entries WHERE scan_id = ?
                ON CONFLICT(id) DO UPDATE SET
                    parent_id = excluded.parent_id, name = excluded.name, kind = excluded.kind,
                    remote_key = excluded.remote_key, content_version = excluded.content_version,
                    metadata_version = excluded.metadata_version, size = excluded.size,
                    modified_at = excluded.modified_at, is_deleted = 0
                """, [.text(scan.parentID), .text(scan.id)])
            try database.execute("DELETE FROM scans WHERE id = ?", [.text(scan.id)])
            try database.execute("UPDATE catalog_state SET generation = generation + 1 WHERE singleton = 1")
            return try database.scalarInt("SELECT generation FROM catalog_state WHERE singleton = 1")
        }
    }

    public func abandonScan(_ scan: CatalogScan) throws {
        try database.transaction {
            try requireScan(scan)
            try database.execute("DELETE FROM scans WHERE id = ?", [.text(scan.id)])
        }
    }

    private func requireScan(_ scan: CatalogScan) throws {
        let count = try database.scalarInt(
            "SELECT count(*) FROM scans WHERE id = ? AND parent_id = ?", [.text(scan.id), .text(scan.parentID)])
        guard count == 1 else { throw CatalogError.invalidScan }
    }

    private func validateNoAncestorReuse(_ scan: CatalogScan) throws {
        let count = try database.scalarInt("""
            WITH RECURSIVE ancestors(id, parent_id) AS (
                SELECT id, parent_id FROM items WHERE id = ?
                UNION
                SELECT items.id, items.parent_id FROM items JOIN ancestors ON items.id = ancestors.parent_id
            )
            SELECT count(*) FROM scan_entries JOIN ancestors ON ancestors.id = scan_entries.item_id
            WHERE scan_id = ?
            """, [.text(scan.parentID), .text(scan.id)])
        guard count == 0 else { throw CatalogError.invalidEntry }
    }

    private func hasChanges(_ scan: CatalogScan) throws -> Bool {
        try database.scalarInt("""
            SELECT EXISTS(
                SELECT 1 FROM scan_entries AS observed LEFT JOIN items AS current ON current.id = observed.item_id
                WHERE observed.scan_id = ? AND (
                    current.id IS NULL OR current.parent_id IS NOT ? OR current.is_deleted != 0
                    OR current.name != observed.name OR current.kind != observed.kind
                    OR current.remote_key IS NOT observed.remote_key
                    OR current.content_version != observed.content_version
                    OR current.metadata_version != observed.metadata_version
                    OR current.size != observed.size OR current.modified_at IS NOT observed.modified_at)
                UNION ALL
                SELECT 1 FROM items WHERE parent_id = ? AND is_deleted = 0
                    AND id NOT IN (SELECT item_id FROM scan_entries WHERE scan_id = ?)
            )
            """, [.text(scan.id), .text(scan.parentID), .text(scan.parentID), .text(scan.id)]) != 0
    }
}
