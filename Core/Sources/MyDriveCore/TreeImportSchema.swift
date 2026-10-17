extension SQLiteConnection {
    func migrateTreeImport() throws {
        try script("""
            CREATE TABLE tree_imports(
                operation_key TEXT PRIMARY KEY REFERENCES operations(idempotency_key),
                tree_id TEXT NOT NULL UNIQUE, node_count INTEGER NOT NULL CHECK(node_count > 0),
                total_bytes INTEGER NOT NULL CHECK(total_bytes >= 0), digest TEXT NOT NULL,
                root_id TEXT NOT NULL, parent_id TEXT NOT NULL, filename TEXT NOT NULL,
                phase TEXT NOT NULL DEFAULT 'building' CHECK(phase IN ('building','frozen','published')),
                parent_path TEXT NOT NULL, parent_index TEXT NOT NULL, parent_created TEXT NOT NULL,
                arena_name TEXT NOT NULL, arena_id TEXT NOT NULL,
                arena_operation_key TEXT NOT NULL UNIQUE, publish_operation_key TEXT NOT NULL UNIQUE,
                arena_entry TEXT, staged_nodes INTEGER NOT NULL DEFAULT 0, staged_bytes INTEGER NOT NULL DEFAULT 0,
                verified_nodes INTEGER NOT NULL DEFAULT 0,
                blocked_code TEXT CHECK(blocked_code IS NULL OR length(CAST(blocked_code AS BLOB)) BETWEEN 1 AND 256)
            );
            CREATE UNIQUE INDEX tree_import_root ON tree_imports(root_id);
            CREATE TABLE tree_import_nodes(
                operation_key TEXT NOT NULL REFERENCES tree_imports(operation_key),
                path TEXT NOT NULL, parent_path TEXT, name TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('file','directory')),
                item_id TEXT NOT NULL, parent_id TEXT NOT NULL, depth INTEGER NOT NULL CHECK(depth BETWEEN 0 AND 128),
                payload TEXT, sealed INTEGER NOT NULL DEFAULT 0 CHECK(sealed IN (0,1)),
                scratch_path TEXT NOT NULL, create_operation_key TEXT NOT NULL UNIQUE, place_operation_key TEXT NOT NULL UNIQUE,
                created_entry TEXT, placed_entry TEXT, verified_entry TEXT, verification_scan TEXT, seen_scan TEXT,
                PRIMARY KEY(operation_key,path), UNIQUE(operation_key,item_id)
            );
            CREATE INDEX tree_import_frontier ON tree_import_nodes(operation_key,depth,path);
            CREATE INDEX tree_import_children ON tree_import_nodes(operation_key,parent_path,path);
            CREATE INDEX tree_import_unplaced ON tree_import_nodes(operation_key,depth,path) WHERE placed_entry IS NULL;
            CREATE INDEX tree_import_unverified ON tree_import_nodes(operation_key,depth DESC,path) WHERE verified_entry IS NULL;
            CREATE INDEX tree_import_unverified_children ON tree_import_nodes(operation_key,parent_path) WHERE verified_entry IS NULL;
            """)
    }
}
