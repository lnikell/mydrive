import Foundation

extension Catalog {
    /// Starts a new observation without touching published children. A new scan
    /// supersedes an interrupted scan for this parent, never the previous listing.
    public func beginScan(of parentID: String = Catalog.rootID) throws -> CatalogScan {
        try database.transaction {
            try requireDirectory(parentID)
            try database.execute("DELETE FROM scans WHERE parent_id = ?", [.text(parentID)])
            let scan = CatalogScan(id: UUID().uuidString, parentID: parentID,
                                   directory: try item(id: parentID), path: try relativePath(id: parentID))
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
                    scan_id, name, kind, remote_key, content_version, metadata_version, size, modified_at,
                    object_index_number, object_created_filetime)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { statement in
                for entry in entries {
                    try statement.bind([
                        .text(scan.id), .text(entry.name), .text(entry.kind.rawValue), SQLValue(entry.remoteKey),
                        .text(entry.contentVersion), .text(entry.metadataVersion), .integer(entry.size),
                        SQLValue(entry.modifiedAt), SQLValue(entry.objectIdentity.map { String($0.indexNumber) }),
                        SQLValue(entry.objectIdentity.map { String($0.createdFiletime) })])
                    _ = try statement.step()
                    try statement.reset()
                }
            }
        }
    }

    /// Call only after the transport confirms an exhaustive successful listing.
    /// Publication, disappearances and stable-identity updates commit atomically.
    /// Without a stable remote key, logical file identity is preserved at the
    /// same path, including atomic saves. Replaced directories get fresh IDs so
    /// their former descendant graph and offline selections cannot be adopted.
    @discardableResult
    public func completeScan(_ scan: CatalogScan, directory: RemoteEntry? = nil) throws -> Int64 {
        try database.transaction {
            try completeScanInTransaction(scan, directory: directory)
        }
    }

    /// Shared by normal publication and qualified recursive inventory capture.
    /// Caller owns the SQLite transaction; no network work occurs in this body.
    func completeScanInTransaction(_ scan: CatalogScan, directory: RemoteEntry? = nil) throws -> Int64 {
        try requireScan(scan)
        try requireDirectory(scan.parentID)
        let directoryChanged = try publishScannedDirectory(directory, for: scan)
        // Files retain the logical Finder ID after a remote atomic save so a
        // pending local edit can reach conflict preservation. Directory identity
        // enrichment requires an unchanged opaque version; changed/replaced
        // directory objects must not adopt the old descendant graph.
        try database.execute("""
            UPDATE scan_entries SET item_id = COALESCE(
                CASE WHEN remote_key IS NOT NULL
                    THEN (SELECT id FROM items WHERE items.remote_key = scan_entries.remote_key)
                    ELSE (SELECT id FROM items WHERE parent_id = ? AND name = scan_entries.name
                          AND kind = scan_entries.kind AND is_deleted = 0
                                  AND (scan_entries.kind = 'file' OR (
                                      (scan_entries.object_index_number IS NULL OR items.object_index_number IS NOT NULL
                                          OR items.content_version = scan_entries.content_version COLLATE BINARY)
                                      AND (items.object_index_number IS NULL OR scan_entries.object_index_number IS NULL
                                          OR (items.object_index_number = scan_entries.object_index_number
                                              AND items.object_created_filetime = scan_entries.object_created_filetime)))))
                END,
                lower(hex(randomblob(16))))
            WHERE scan_id = ?
            """, [.text(scan.parentID), .text(scan.id)])
        // Legacy observations may omit object identity. Once learned, keep
        // it until a positively observed replacement receives a fresh ID.
        try database.execute("""
            UPDATE scan_entries SET
                object_index_number = (SELECT object_index_number FROM items WHERE id = scan_entries.item_id),
                object_created_filetime = (SELECT object_created_filetime FROM items WHERE id = scan_entries.item_id)
            WHERE scan_id = ? AND object_index_number IS NULL
            """, [.text(scan.id)])
        try validateNoAncestorReuse(scan)
        try database.execute("INSERT OR IGNORE INTO observed_directories(item_id) VALUES (?)", [.text(scan.parentID)])
        if try !hasChanges(scan) {
            try database.execute("DELETE FROM scans WHERE id = ?", [.text(scan.id)])
            if directoryChanged {
                try database.execute("UPDATE catalog_state SET generation = generation + 1 WHERE singleton = 1")
            }
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
            id, parent_id, name, kind, remote_key, content_version, metadata_version, size, modified_at,
            is_deleted, object_index_number, object_created_filetime)
        SELECT item_id, ?, name, kind, remote_key, content_version, metadata_version, size, modified_at,
            0, object_index_number, object_created_filetime
        FROM scan_entries WHERE scan_id = ?
        ON CONFLICT(id) DO UPDATE SET
            parent_id = excluded.parent_id, name = excluded.name, kind = excluded.kind,
            remote_key = excluded.remote_key, content_version = excluded.content_version,
            metadata_version = excluded.metadata_version, size = excluded.size,
            modified_at = excluded.modified_at, is_deleted = 0,
            object_index_number = excluded.object_index_number,
            object_created_filetime = excluded.object_created_filetime
        """, [.text(scan.parentID), .text(scan.id)])
    try database.execute("DELETE FROM scans WHERE id = ?", [.text(scan.id)])
    try database.execute("UPDATE catalog_state SET generation = generation + 1 WHERE singleton = 1")
    return try database.scalarInt("SELECT generation FROM catalog_state WHERE singleton = 1")
    }

    public func abandonScan(_ scan: CatalogScan) throws {
        try database.transaction {
            try requireScan(scan)
            try database.execute("DELETE FROM scans WHERE id = ?", [.text(scan.id)])
        }
    }

    /// The terminal observation comes from the actual held listing handle.
    /// Refresh only mutable metadata of that same frozen directory. Names,
    /// ancestry, identity, stable remote keys and offline selection stay owned
    /// by their existing publication paths; the synthetic root is never remote.
    private func publishScannedDirectory(_ directory: RemoteEntry?, for scan: CatalogScan) throws -> Bool {
        guard let directory, scan.parentID != Self.rootID else { return false }
        try Self.validateMutationEntry(directory)
        guard let frozen = scan.directory, !frozen.isDeleted, frozen.entry.kind == .directory,
              let identity = frozen.entry.objectIdentity, identity.indexNumber != 0, identity.createdFiletime != 0,
              directory.kind == .directory, directory.objectIdentity == identity,
              Self.exact(directory.name, frozen.entry.name),
              let live = try item(id: scan.parentID), !live.isDeleted, live.entry.kind == .directory,
              live.entry.objectIdentity == identity, Self.exact(live.entry.name, frozen.entry.name),
              let frozenParent = frozen.parentID, let liveParent = live.parentID, Self.exact(frozenParent, liveParent),
              let frozenPath = scan.path, let livePath = try relativePath(id: scan.parentID),
              Self.exact(frozenPath, livePath) else { throw CatalogError.invalidParent }
        let changed = !Self.exact(live.entry.contentVersion, directory.contentVersion)
            || !Self.exact(live.entry.metadataVersion, directory.metadataVersion)
            || live.entry.size != directory.size || live.entry.modifiedAt != directory.modifiedAt
        if changed {
            try database.execute("""
                UPDATE items SET content_version = ?, metadata_version = ?, size = ?, modified_at = ? WHERE id = ?
                """, [.text(directory.contentVersion), .text(directory.metadataVersion), .integer(directory.size),
                      SQLValue(directory.modifiedAt), .text(scan.parentID)])
        }
        return changed
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
                    OR current.object_index_number IS NOT observed.object_index_number
                    OR current.object_created_filetime IS NOT observed.object_created_filetime
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
