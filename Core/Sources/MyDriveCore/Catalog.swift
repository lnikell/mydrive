import Foundation

/// One local catalog per configured NAS share. The domain coordinator owns this
/// actor and all scheduling. Calls do no network I/O and retain only bounded pages.
public actor Catalog {
    public static let rootID = "root"
    let database: SQLiteConnection

    public init(databaseURL: URL, cacheSizeKiB: Int = 2_048) throws {
        database = try SQLiteConnection(url: databaseURL, cacheKiB: cacheSizeKiB)
        try database.migrate()
    }

    public func settings() throws -> CatalogSettings {
        try CatalogSettings(
            journalMode: database.scalarText("PRAGMA journal_mode"),
            synchronous: database.scalarInt("PRAGMA synchronous"),
            cacheSizeKiB: -database.scalarInt("PRAGMA cache_size"))
    }

    public func item(id: String) throws -> CatalogItem? {
        try database.statement("SELECT \(Self.itemColumns) FROM items WHERE id = ?", [.text(id)]) {
            try $0.step() ? Self.decodeItem($0) : nil
        }
    }

    /// Exact byte spelling is resolved by SQLite's binary name index. This is
    /// independent of listing cursors and never scans all siblings to find one.
    public func child(named name: String, in parentID: String) throws -> CatalogItem? {
        try Self.validateName(name)
        try requireDirectory(parentID)
        return try database.statement("""
            SELECT \(Self.itemColumns) FROM items
            WHERE parent_id = ? AND is_deleted = 0 AND name = ? COLLATE BINARY
            ORDER BY id LIMIT 2
            """, [.text(parentID), .text(name)]) { statement in
                guard try statement.step() else { return nil }
                let result = try Self.decodeItem(statement)
                guard try !statement.step() else { throw CatalogError.invalidEntry }
                return result
            }
    }

    public func generation() throws -> Int64 {
        try database.scalarInt("SELECT generation FROM catalog_state WHERE singleton = 1")
    }

    public func hasCompletedScan(of parentID: String) throws -> Bool {
        try database.scalarInt("""
            SELECT count(*) FROM observed_directories JOIN items ON items.id = observed_directories.item_id
            WHERE items.id = ? AND items.kind = 'directory' AND items.is_deleted = 0
            """, [.text(parentID)]) != 0
    }

    /// Bounded traversal of all known live items, excluding root. The caller
    /// validates generation before continuing; ID ordering is independent of names.
    public func knownItems(afterID: String? = nil, limit: Int = 128) throws -> [CatalogItem] {
        try Self.validatePageSize(limit)
        let continuation = afterID == nil ? "" : "AND id > ?"
        var values = afterID.map { [SQLValue.text($0)] } ?? []
        values.append(.integer(Int64(limit)))
        return try database.statement("""
            SELECT \(Self.itemColumns) FROM items
            WHERE is_deleted = 0 AND id != 'root' \(continuation)
            ORDER BY id LIMIT ?
            """, values) { statement in
                var items: [CatalogItem] = []
                while try statement.step() { items.append(try Self.decodeItem(statement)) }
                return items
            }
    }

    /// Previously scanned live directories, excluding root, which the coordinator
    /// refreshes separately. This is a live keyset, not a generation-bound snapshot:
    /// new observations before the bookmark are picked up by the next refresh pass.
    public func observedDirectories(afterID: String? = nil, limit: Int = 128) throws -> [CatalogItem] {
        try Self.validatePageSize(limit)
        let continuation = afterID == nil ? "" : "AND observed.item_id > ?"
        var values = afterID.map { [SQLValue.text($0)] } ?? []
        values.append(.integer(Int64(limit)))
        // Keep the observed-directory index as the outer loop. An ordinary JOIN
        // can scan every live file and sort the result before applying LIMIT.
        return try database.statement("""
            SELECT \(Self.itemColumns) FROM observed_directories AS observed
            CROSS JOIN items ON items.id = observed.item_id
            WHERE observed.item_id != 'root' AND items.is_deleted = 0 AND items.kind = 'directory'
                \(continuation)
            ORDER BY observed.item_id LIMIT ?
            """, values) { statement in
                var items: [CatalogItem] = []
                while try statement.step() { items.append(try Self.decodeItem(statement)) }
                return items
            }
    }

    /// Returns a slash-separated path relative to the configured share, or nil
    /// when the item or an ancestor is unpublished/deleted. Root is "".
    public func relativePath(id: String) throws -> String? {
        try database.statement("""
            WITH RECURSIVE path(id, parent_id, relative_path, depth) AS (
                SELECT id, parent_id, name, 0 FROM items WHERE id = ? AND is_deleted = 0
                UNION ALL
                SELECT parent.id, parent.parent_id,
                    CASE WHEN parent.id = 'root' THEN path.relative_path
                         ELSE parent.name || '/' || path.relative_path END,
                    path.depth + 1
                FROM items AS parent JOIN path ON parent.id = path.parent_id
                WHERE parent.is_deleted = 0 AND parent.kind = 'directory' AND path.depth < 1024
            )
            SELECT relative_path FROM path WHERE id = 'root'
            """, [.text(id)]) { try $0.step() ? $0.text(0) : nil }
    }

    public func children(
        of parentID: String = Catalog.rootID, after cursor: ListingCursor? = nil,
        limit: Int = 128
    ) throws -> CatalogPage {
        try Self.validatePageSize(limit)
        if let cursor, cursor.parentID != parentID { throw CatalogError.invalidCursor }
        return try database.transaction(write: false) {
            try requireDirectory(parentID)
            let generation = try database.scalarInt("SELECT generation FROM catalog_state WHERE singleton = 1")
            if let cursor, cursor.generation != generation { throw CatalogError.staleCursor }
            var values: [SQLValue] = [.text(parentID)]
            var condition = ""
            if let cursor {
                // Row-value continuation lets SQLite seek directly into the
                // children index instead of visiting every preceding page.
                condition = "AND (name, id) > (?, ?)"
                values += [.text(cursor.lastName), .text(cursor.lastID)]
            }
            values.append(.integer(Int64(limit + 1)))
            var items = try database.statement("""
                SELECT \(Self.itemColumns) FROM items
                WHERE parent_id = ? AND is_deleted = 0 \(condition)
                ORDER BY name COLLATE BINARY, id LIMIT ?
                """, values) { statement in
                    var items: [CatalogItem] = []
                    while try statement.step() { items.append(try Self.decodeItem(statement)) }
                    return items
                }
            let hasMore = items.count > limit
            if hasMore { items.removeLast() }
            let next = hasMore ? items.last.map {
                ListingCursor(parentID: parentID, generation: generation, lastName: $0.entry.name, lastID: $0.id)
            } : nil
            return CatalogPage(items: items, nextCursor: next, generation: generation)
        }
    }

    public func setOfflinePolicy(_ policy: OfflinePolicy, for itemID: String) throws {
        try database.transaction {
            guard try item(id: itemID) != nil else { throw CatalogError.missingItem(itemID) }
            switch policy {
            case .onDemand:
                try database.execute("DELETE FROM offline_policy WHERE item_id = ?", [.text(itemID)])
            case .keepAvailable:
                try database.execute("""
                    INSERT INTO offline_policy(item_id, policy) VALUES (?, ?)
                    ON CONFLICT(item_id) DO UPDATE SET policy = excluded.policy
                    WHERE offline_policy.policy != excluded.policy
                    """, [.text(itemID), .text(policy.rawValue)])
            }
            try advanceGenerationIfChanged()
        }
    }

    /// A folder selection applies to its descendants. onDemand removes only the
    /// item's own selection; an ancestor selection still applies.
    public func offlinePolicy(for itemID: String) throws -> OfflinePolicy {
        guard try item(id: itemID) != nil else { throw CatalogError.missingItem(itemID) }
        let count = try database.scalarInt("""
            WITH RECURSIVE ancestors(id, parent_id) AS (
                SELECT id, parent_id FROM items WHERE id = ?
                UNION
                SELECT items.id, items.parent_id FROM items JOIN ancestors ON items.id = ancestors.parent_id
            )
            SELECT count(*) FROM offline_policy JOIN ancestors ON ancestors.id = offline_policy.item_id
            WHERE policy = 'keepAvailable'
            """, [.text(itemID)])
        return count > 0 ? .keepAvailable : .onDemand
    }

    /// Changes policy only. File eviction is a separate File Provider operation
    /// that must preserve dirty/open content; the catalog never removes file bytes.
    public func clearOfflineSelections(in subtreeID: String = Catalog.rootID) throws {
        try database.transaction {
            guard try item(id: subtreeID) != nil else { throw CatalogError.missingItem(subtreeID) }
            try database.execute("""
                WITH RECURSIVE descendants(id) AS (
                    SELECT id FROM items WHERE id = ?
                    UNION
                    SELECT items.id FROM items JOIN descendants ON items.parent_id = descendants.id
                )
                DELETE FROM offline_policy WHERE item_id IN (SELECT id FROM descendants)
                """, [.text(subtreeID)])
            try advanceGenerationIfChanged()
        }
    }

    /// Lists explicit selections, not every inheriting descendant. Continue with
    /// the last returned ID; refresh this settings view when selections change.
    public func offlineSelections(afterID: String? = nil, limit: Int = 128) throws -> [CatalogItem] {
        try Self.validatePageSize(limit)
        let continuation = afterID == nil ? "" : "AND id > ?"
        var values = afterID.map { [SQLValue.text($0)] } ?? []
        values.append(.integer(Int64(limit)))
        return try database.statement("""
            SELECT \(Self.itemColumns) FROM items
            WHERE is_deleted = 0 AND id IN (SELECT item_id FROM offline_policy WHERE policy = 'keepAvailable')
                \(continuation)
            ORDER BY id LIMIT ?
            """, values) { statement in
                var items: [CatalogItem] = []
                while try statement.step() { items.append(try Self.decodeItem(statement)) }
                return items
            }
    }

    public func setConnectionState(_ state: ConnectionState) throws {
        try database.execute("UPDATE catalog_state SET connection = ? WHERE singleton = 1", [.text(state.rawValue)])
    }

    public func connectionState() throws -> ConnectionState {
        let raw = try database.scalarText("SELECT connection FROM catalog_state WHERE singleton = 1")
        guard let state = ConnectionState(rawValue: raw) else { throw CatalogError.invalidEntry }
        return state
    }

    func requireDirectory(_ id: String) throws {
        guard let item = try item(id: id), item.entry.kind == .directory, !item.isDeleted else {
            throw CatalogError.invalidParent
        }
    }

    private func advanceGenerationIfChanged() throws {
        if try database.scalarInt("SELECT changes()") > 0 {
            try database.execute("UPDATE catalog_state SET generation = generation + 1 WHERE singleton = 1")
        }
    }

    static func validatePageSize(_ limit: Int) throws {
        guard (1...1_000).contains(limit) else { throw CatalogError.invalidPageSize }
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw CatalogError.invalidName
        }
    }

    static let itemColumns = "id, parent_id, name, kind, remote_key, content_version, metadata_version, size, modified_at, is_deleted"

    static func decodeItem(_ statement: SQLStatement) throws -> CatalogItem {
        guard let kind = ItemKind(rawValue: statement.text(3)) else { throw CatalogError.invalidEntry }
        let modified = statement.isNull(8) ? nil : Date(timeIntervalSince1970: statement.real(8))
        return CatalogItem(
            id: statement.text(0), parentID: statement.optionalText(1),
            entry: RemoteEntry(
                name: statement.text(2), kind: kind, remoteKey: statement.optionalText(4),
                contentVersion: statement.text(5), metadataVersion: statement.text(6),
                size: statement.integer(7), modifiedAt: modified),
            isDeleted: statement.integer(9) != 0)
    }
}
