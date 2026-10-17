import Foundation

extension SQLiteConnection {
    /// Called inside the canonical schema migration transaction. A create owns
    /// an ID before publication, so the journal must not require a live item FK.
    func migrateWritableJournal() throws {
        try script("""
            ALTER TABLE operations RENAME TO operations_legacy;
            DROP INDEX replay;
            CREATE TABLE operations (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                idempotency_key TEXT NOT NULL UNIQUE,
                item_id TEXT NOT NULL,
                intent TEXT NOT NULL,
                state TEXT NOT NULL,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                request_fingerprint TEXT,
                commit_fingerprint TEXT,
                result TEXT
            );
            INSERT INTO operations(sequence, idempotency_key, item_id, intent, state, attempt_count)
                SELECT sequence, idempotency_key, item_id, intent, state, attempt_count FROM operations_legacy;
            DROP TABLE operations_legacy;
            CREATE INDEX replay ON operations(state, sequence);
            CREATE UNIQUE INDEX operation_request ON operations(request_fingerprint)
                WHERE request_fingerprint IS NOT NULL;
            CREATE TABLE create_bindings (
                template_id TEXT PRIMARY KEY,
                item_id TEXT NOT NULL UNIQUE
            );
            """)
    }
}
