import Foundation

extension Catalog {
    /// Immutable inventory metadata, including already removed nodes. This is
    /// suitable for a whole-selection preflight without adopting the live tree.
    /// Building manifests are incomplete and cannot be inspected as authority.
    public func recursiveDeleteInventory(
        key: UUID, afterID: String? = nil, limit: Int = 128
    ) throws -> [CatalogItem] {
        try Self.validatePageSize(limit)
        if let afterID { try Self.validateMutationID(afterID) }
        return try database.transaction(write: false) {
            let status = try requireRecursiveStatus(key)
            guard status.phase == .frozen || status.phase == .completed else {
                throw CatalogError.invalidTransition
            }
            let continuation = afterID == nil ? "" : "AND node.item_id > ?"
            var values: [SQLValue] = [.text(key.uuidString)]
            if let afterID { values.append(.text(afterID)) }
            values.append(.integer(Int64(limit)))
            return try database.statement("""
                SELECT \(Self.deleteNodeColumns) FROM recursive_delete_nodes AS node
                WHERE node.operation_key = ? \(continuation)
                ORDER BY node.item_id LIMIT ?
                """, values) { statement in
                    var items: [CatalogItem] = []
                    while try statement.step() { items.append(try Self.decodeDeleteNode(statement).item) }
                    return items
                }
        }
    }
}
