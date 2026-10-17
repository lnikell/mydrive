extension SQLiteConnection {
    /// Decimal TEXT preserves the full unsigned SMB values without signed
    /// SQLite INTEGER conversion. Existing observations remain unknown (NULL).
    func migrateObjectIdentity() throws {
        for table in ["items", "scan_entries"] {
            try execute("ALTER TABLE \(table) ADD COLUMN object_index_number TEXT")
            try execute("ALTER TABLE \(table) ADD COLUMN object_created_filetime TEXT")
        }
        try script("""
            DROP TRIGGER record_item_update;
            CREATE TRIGGER record_item_update AFTER UPDATE ON items
            WHEN OLD.parent_id IS NOT NEW.parent_id OR OLD.name IS NOT NEW.name
                OR OLD.kind IS NOT NEW.kind OR OLD.remote_key IS NOT NEW.remote_key
                OR OLD.content_version IS NOT NEW.content_version OR OLD.metadata_version IS NOT NEW.metadata_version
                OR OLD.size IS NOT NEW.size OR OLD.modified_at IS NOT NEW.modified_at OR OLD.is_deleted IS NOT NEW.is_deleted
                OR OLD.object_index_number IS NOT NEW.object_index_number
                OR OLD.object_created_filetime IS NOT NEW.object_created_filetime
            BEGIN
                INSERT INTO catalog_changes(item_id, old_parent_id, new_parent_id)
                VALUES (NEW.id, OLD.parent_id, NEW.parent_id);
            END;
            """)
    }
}
