import Foundation

extension Catalog {
    /// One canonical identity resolver serves terminal scans and the narrow
    /// first-visible prefix. A published scan binding is never minted again.
    func resolveScannedIdentities(_ scan: CatalogScan, visibleAfter rowID: Int64? = nil) throws {
        let (sql, values) = Self.scannedIdentityAssignment(scan, visibleAfter: rowID)
        try database.execute(sql, values)
        // Prefix candidates already have typed identities. Only terminal
        // resolution enriches legacy observations across the complete scan.
        guard rowID == nil else { return }
        try database.execute("""
            UPDATE scan_entries SET
                object_index_number = (SELECT object_index_number FROM items WHERE id = scan_entries.item_id),
                object_created_filetime = (SELECT object_created_filetime FROM items WHERE id = scan_entries.item_id)
            WHERE scan_id = ? AND object_index_number IS NULL
            """, [.text(scan.id)])
    }

    // Fixed statement builders keep query-plan regressions on the exact SQL
    // used by both publication paths, including their bound rowid scope.
    static func scannedIdentityAssignment(_ scan: CatalogScan, visibleAfter rowID: Int64? = nil) -> (String, [SQLValue]) {
        let selection: String
        let selectedValues: [SQLValue]
        if let rowID {
            selection = """
                AND rowid IN (
                    SELECT observed.rowid FROM scan_entries AS observed NOT INDEXED
                    WHERE observed.scan_id = ? AND observed.rowid > ?
                        AND observed.kind IN ('file','directory')
                        AND observed.object_index_number IS NOT NULL AND observed.object_index_number != '0'
                        AND observed.object_created_filetime IS NOT NULL AND observed.object_created_filetime != '0'
                        AND NOT EXISTS(SELECT 1 FROM items AS known
                            WHERE known.parent_id = ? AND known.is_deleted IN (0,1) AND known.name = observed.name)
                        AND NOT EXISTS(SELECT 1 FROM items AS known
                            WHERE known.remote_key = observed.remote_key)
                        AND NOT EXISTS(SELECT 1 FROM items AS known
                            WHERE known.object_index_number = observed.object_index_number
                                AND known.object_created_filetime = observed.object_created_filetime)
                    ORDER BY observed.name COLLATE BINARY LIMIT 128)
                """
            selectedValues = [.text(scan.id), .integer(rowID), .text(scan.parentID)]
        } else { selection = ""; selectedValues = [] }
        // Files retain the logical Finder ID after a remote atomic save so a
        // pending local edit can reach conflict preservation. Directory identity
        // enrichment requires an unchanged opaque version; changed/replaced
        // directory objects must not adopt the old descendant graph.
        return ("""
            UPDATE scan_entries \(rowID == nil ? "" : "NOT INDEXED") SET item_id = COALESCE(
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
            WHERE scan_id = ? AND item_id IS NULL \(selection)
            """, [.text(scan.parentID), .text(scan.id)] + selectedValues)
    }

    func publishScannedRows(_ scan: CatalogScan, visibleAfter rowID: Int64? = nil) throws {
        let (sql, values) = Self.scannedPublication(scan, visibleAfter: rowID)
        try database.execute(sql, values)
    }

    static func scannedPublication(_ scan: CatalogScan, visibleAfter rowID: Int64? = nil) -> (String, [SQLValue]) {
        ("""
            INSERT INTO items(
                id, parent_id, name, kind, remote_key, content_version, metadata_version, size, modified_at,
                is_deleted, object_index_number, object_created_filetime)
            SELECT item_id, ?, name, kind, remote_key, content_version, metadata_version, size, modified_at,
                0, object_index_number, object_created_filetime
            FROM scan_entries \(rowID == nil ? "" : "NOT INDEXED")
            WHERE scan_id = ? AND item_id IS NOT NULL \(rowID == nil ? "" : "AND rowid > ?")
            ON CONFLICT(id) DO UPDATE SET
                parent_id = excluded.parent_id, name = excluded.name, kind = excluded.kind,
                remote_key = excluded.remote_key, content_version = excluded.content_version,
                metadata_version = excluded.metadata_version, size = excluded.size,
                modified_at = excluded.modified_at, is_deleted = 0,
                object_index_number = excluded.object_index_number,
                object_created_filetime = excluded.object_created_filetime
            """, [.text(scan.parentID), .text(scan.id)] + (rowID.map { [.integer($0)] } ?? []))
    }

    func retireMissingScanRows(_ scan: CatalogScan) throws {
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
    }
}
