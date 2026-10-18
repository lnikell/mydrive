import Foundation

extension Catalog {
    /// Counts only published, live paths reachable from root. Offline policy
    /// inheritance is evaluated once in the tree rather than per leaf.
    public func libraryCounts() throws -> (onDemandFiles: Int64, explicitSelections: Int64) {
        try database.statement("""
            WITH RECURSIVE live(id, kind, kept, selected) AS (
                SELECT id, kind, EXISTS(SELECT 1 FROM offline_policy WHERE item_id = items.id),
                    EXISTS(SELECT 1 FROM offline_policy WHERE item_id = items.id)
                FROM items WHERE id = 'root' AND is_deleted = 0
                UNION ALL
                SELECT child.id, child.kind,
                    live.kept OR EXISTS(SELECT 1 FROM offline_policy WHERE item_id = child.id),
                    EXISTS(SELECT 1 FROM offline_policy WHERE item_id = child.id)
                FROM items AS child JOIN live ON child.parent_id = live.id
                WHERE child.is_deleted = 0 AND live.kind = 'directory'
            )
            SELECT coalesce(sum(kind = 'file' AND kept = 0), 0), coalesce(sum(selected), 0) FROM live
            """) { statement in
                guard try statement.step() else { throw CatalogError.invalidEntry }
                return (statement.integer(0), statement.integer(1))
            }
    }
}
