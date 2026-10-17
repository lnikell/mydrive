import Foundation

extension SQLiteConnection {
    func migrate() throws {
        try transaction {
            let version = try scalarInt("PRAGMA user_version")
            guard (0...8).contains(version) else { throw CatalogError.unsupportedSchema(Int(version)) }
            guard version != 8 else { return }
            if version == 1 {
                try script("""
                    CREATE TABLE IF NOT EXISTS observed_directories (item_id TEXT PRIMARY KEY REFERENCES items(id));
                    CREATE INDEX IF NOT EXISTS live_items ON items(is_deleted, id);
                    PRAGMA user_version = 2;
                    """)
            } else if version == 0 {
              try script("""
                CREATE TABLE catalog_state (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    generation INTEGER NOT NULL,
                    connection TEXT NOT NULL
                );
                INSERT INTO catalog_state VALUES (1, 0, 'unknown');
                CREATE TABLE items (
                    id TEXT PRIMARY KEY,
                    parent_id TEXT REFERENCES items(id),
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    remote_key TEXT UNIQUE,
                    content_version TEXT NOT NULL,
                    metadata_version TEXT NOT NULL,
                    size INTEGER NOT NULL CHECK(size >= 0),
                    modified_at REAL,
                    is_deleted INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX children ON items(parent_id, is_deleted, name, id);
                CREATE INDEX live_items ON items(is_deleted, id);
                INSERT INTO items VALUES ('root', NULL, '', 'directory', NULL, '', '', 0, NULL, 0);
                CREATE TABLE offline_policy (
                    item_id TEXT PRIMARY KEY REFERENCES items(id),
                    policy TEXT NOT NULL
                );
                CREATE TABLE observed_directories (
                    item_id TEXT PRIMARY KEY REFERENCES items(id)
                );
                CREATE TABLE scans (
                    id TEXT PRIMARY KEY,
                    parent_id TEXT NOT NULL UNIQUE REFERENCES items(id)
                );
                CREATE TABLE scan_entries (
                    scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    remote_key TEXT,
                    content_version TEXT NOT NULL,
                    metadata_version TEXT NOT NULL,
                    size INTEGER NOT NULL CHECK(size >= 0),
                    modified_at REAL,
                    item_id TEXT,
                    PRIMARY KEY(scan_id, name)
                );
                CREATE UNIQUE INDEX scan_remote_keys ON scan_entries(scan_id, remote_key)
                    WHERE remote_key IS NOT NULL;
                CREATE TABLE operations (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    idempotency_key TEXT NOT NULL UNIQUE,
                    item_id TEXT NOT NULL REFERENCES items(id),
                    intent TEXT NOT NULL,
                    state TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX replay ON operations(state, sequence);
                PRAGMA user_version = 2;
                """)
            }
            if version < 3 { try migrateChangeFeed() }
            // Version 3 was the first incremental feed. Keep its item-scoped
            // lookup indexed when migrating an already-created feed database.
            try execute("CREATE INDEX IF NOT EXISTS changes_item ON catalog_changes(item_id, sequence)")
            if version < 4 { try migrateWritableJournal() }
            if version < 5 { try migrateObjectIdentity() }
            if version < 6 { try migrateRecursiveDelete() }
            if version < 7 { try migrateTreeImport() }
            try migrateTreeImportLayout()
            try execute("PRAGMA user_version = 8")
        }
    }
}
