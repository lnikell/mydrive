import Foundation

public enum ChangeFeedError: Error, Equatable, Sendable {
    case invalidAnchor
}

public struct CatalogChangePage: Sendable {
    public let updated: [CatalogItem]
    public let deletedIDs: [String]
    public let anchor: Int64
    public let moreComing: Bool
}

extension Catalog {
    /// Monotonic committed changes, independent of listing cursors. The old
    /// generation-only anchors expire once when the adapter adopts this feed.
    public func currentChangeAnchor() throws -> Int64 {
        try database.scalarInt("SELECT COALESCE(MAX(sequence), 0) FROM catalog_changes")
    }

    /// Each bounded page resolves its IDs to their current state. Repeated
    /// changes collapse within a page; later pages may safely repeat an item.
    /// A move updates the working set and deletes from its former directory.
    public func changes(since anchor: Int64, in parentID: String? = nil, itemID: String? = nil,
                        limit: Int = 128) throws -> CatalogChangePage {
        try Self.validatePageSize(limit)
        guard parentID == nil || itemID == nil else { throw CatalogError.invalidParent }
        return try database.transaction(write: false) {
            let current = try currentChangeAnchor()
            let floor = try database.scalarInt("SELECT floor FROM catalog_change_state WHERE singleton = 1")
            guard anchor >= floor, anchor <= current else { throw ChangeFeedError.invalidAnchor }
            var values: [SQLValue] = [.integer(anchor), .integer(current)]
            var scope = ""
            if let parentID {
                scope = "AND (old_parent_id = ? OR new_parent_id = ?)"
                values += [.text(parentID), .text(parentID)]
            } else if let itemID {
                scope = "AND item_id = ?"
                values.append(.text(itemID))
            }
            values.append(.integer(Int64(limit + 1)))
            var events = try database.statement("""
                SELECT sequence, item_id FROM catalog_changes
                WHERE sequence > ? AND sequence <= ? \(scope)
                ORDER BY sequence LIMIT ?
                """, values) { statement in
                    var events: [(Int64, String)] = []
                    while try statement.step() { events.append((statement.integer(0), statement.text(1))) }
                    return events
                }
            let more = events.count > limit
            if more { events.removeLast() }
            var updated: [CatalogItem] = []
            var deleted: [String] = []
            var seen = Set<String>()
            for (_, id) in events where seen.insert(id).inserted {
                if let value = try item(id: id), !value.isDeleted,
                   parentID == nil || value.parentID == parentID {
                    updated.append(value)
                } else {
                    deleted.append(id)
                }
            }
            return CatalogChangePage(updated: updated, deletedIDs: deleted,
                                     anchor: more ? events.last!.0 : current, moreComing: more)
        }
    }
}

extension SQLiteConnection {
    /// Triggers keep every Catalog publication path in the same transaction as
    /// its changes. History uses about 50k rows, with at most 1023 extra between
    /// pruning passes; older anchors request a complete enumeration.
    func migrateChangeFeed() throws {
        try script("""
            CREATE TABLE catalog_change_state (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1), floor INTEGER NOT NULL
            );
            INSERT INTO catalog_change_state VALUES (1, 0);
            CREATE TABLE catalog_changes (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT NOT NULL,
                old_parent_id TEXT, new_parent_id TEXT
            );
            CREATE INDEX changes_old_parent ON catalog_changes(old_parent_id, sequence);
            CREATE INDEX changes_new_parent ON catalog_changes(new_parent_id, sequence);
            CREATE INDEX changes_item ON catalog_changes(item_id, sequence);
            CREATE TRIGGER record_item_insert AFTER INSERT ON items BEGIN
                INSERT INTO catalog_changes(item_id, new_parent_id) VALUES (NEW.id, NEW.parent_id);
            END;
            CREATE TRIGGER record_item_update AFTER UPDATE ON items
            WHEN OLD.parent_id IS NOT NEW.parent_id OR OLD.name IS NOT NEW.name
                OR OLD.kind IS NOT NEW.kind OR OLD.remote_key IS NOT NEW.remote_key
                OR OLD.content_version IS NOT NEW.content_version OR OLD.metadata_version IS NOT NEW.metadata_version
                OR OLD.size IS NOT NEW.size OR OLD.modified_at IS NOT NEW.modified_at OR OLD.is_deleted IS NOT NEW.is_deleted
            BEGIN
                INSERT INTO catalog_changes(item_id, old_parent_id, new_parent_id)
                VALUES (NEW.id, OLD.parent_id, NEW.parent_id);
            END;
            CREATE TRIGGER record_item_delete AFTER DELETE ON items BEGIN
                INSERT INTO catalog_changes(item_id, old_parent_id) VALUES (OLD.id, OLD.parent_id);
            END;
            CREATE TRIGGER bound_change_history AFTER INSERT ON catalog_changes
            WHEN NEW.sequence > 50000 AND NEW.sequence % 1024 = 0 BEGIN
                UPDATE catalog_change_state SET floor = NEW.sequence - 50000 WHERE singleton = 1;
                DELETE FROM catalog_changes WHERE sequence <= NEW.sequence - 50000;
            END;
            """)
        // Offline selection affects descendants through inheritance. Recording
        // the subtree also reaches already-materialized files in the working set.
        for event in ["INSERT", "UPDATE", "DELETE"] {
            let value = event == "DELETE" ? "OLD" : "NEW"
            let condition = event == "UPDATE" ? "WHEN OLD.policy IS NOT NEW.policy" : ""
            try script("""
                CREATE TRIGGER record_policy_\(event.lowercased()) AFTER \(event) ON offline_policy \(condition) BEGIN
                    INSERT INTO catalog_changes(item_id, old_parent_id, new_parent_id)
                    WITH RECURSIVE subtree(id) AS (
                        SELECT \(value).item_id
                        UNION SELECT items.id FROM items JOIN subtree ON items.parent_id = subtree.id
                    )
                    SELECT items.id, items.parent_id, items.parent_id FROM items JOIN subtree ON subtree.id = items.id;
                END;
                """)
        }
    }
}
