extension SQLiteConnection {
    func migrateRecursiveDelete() throws {
        try script("""
            CREATE TABLE domain_versions(
                epoch INTEGER PRIMARY KEY CHECK(epoch >= 0), context_id TEXT NOT NULL UNIQUE,
                archive TEXT NOT NULL CHECK(length(archive) BETWEEN 1 AND 43692)
            );
            CREATE TABLE recursive_deletes(
                operation_key TEXT PRIMARY KEY REFERENCES operations(idempotency_key),
                root_id TEXT NOT NULL, phase TEXT NOT NULL DEFAULT 'building' CHECK(phase IN ('building','frozen','completed')),
                context_epoch INTEGER REFERENCES domain_versions(epoch), fence_epoch INTEGER NOT NULL,
                request_context TEXT CHECK(request_context IS NULL OR length(request_context) <= 43692),
                total_nodes INTEGER NOT NULL DEFAULT 1 CHECK(total_nodes >= 1),
                removed_nodes INTEGER NOT NULL DEFAULT 0 CHECK(removed_nodes >= 0),
                blocked_nodes INTEGER NOT NULL DEFAULT 0 CHECK(blocked_nodes >= 0),
                root_path TEXT NOT NULL CHECK(length(CAST(root_path AS BLOB)) BETWEEN 1 AND 4096),
                root_index TEXT NOT NULL, root_created TEXT NOT NULL,
                parent_path TEXT NOT NULL CHECK(length(CAST(parent_path AS BLOB)) <= 4096),
                parent_index TEXT NOT NULL, parent_created TEXT NOT NULL,
                CHECK(removed_nodes + blocked_nodes <= total_nodes)
            );
            CREATE INDEX recursive_root ON recursive_deletes(root_id, fence_epoch DESC);
            CREATE INDEX recursive_context ON recursive_deletes(root_id, context_epoch);
            CREATE TABLE recursive_delete_nodes(
                operation_key TEXT NOT NULL REFERENCES recursive_deletes(operation_key),
                item_id TEXT NOT NULL, parent_id TEXT NOT NULL, name TEXT NOT NULL,
                path TEXT NOT NULL CHECK(length(CAST(path AS BLOB)) BETWEEN 1 AND 65536),
                kind TEXT NOT NULL CHECK(kind IN ('file','directory')), depth INTEGER NOT NULL CHECK(depth BETWEEN 0 AND 128),
                observation TEXT NOT NULL CHECK(length(CAST(observation AS BLOB)) <= 65536),
                parent_index TEXT NOT NULL, parent_created TEXT NOT NULL,
                child_operation_key TEXT NOT NULL,
                captured INTEGER NOT NULL DEFAULT 0 CHECK(captured IN (0,1)),
                removed INTEGER NOT NULL DEFAULT 0 CHECK(removed IN (0,1)),
                blocked_code TEXT CHECK(blocked_code IS NULL OR length(CAST(blocked_code AS BLOB)) BETWEEN 1 AND 256),
                PRIMARY KEY(operation_key,item_id), UNIQUE(operation_key,path), UNIQUE(operation_key,child_operation_key)
            );
            CREATE INDEX recursive_capture ON recursive_delete_nodes(operation_key,kind,captured,depth DESC,item_id);
            CREATE INDEX recursive_pending ON recursive_delete_nodes(operation_key,removed,depth DESC,item_id);
            CREATE INDEX recursive_children ON recursive_delete_nodes(operation_key,parent_id,removed);
            """)
    }
}
