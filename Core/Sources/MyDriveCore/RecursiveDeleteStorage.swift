import Foundation

struct DeleteNode {
    let item: CatalogItem
    let path: String
    let depth: Int
    let parentIdentity: RemoteObjectIdentity
    let operationKey: UUID
    let captured: Bool
    let removed: Bool
    let blockedCode: String?
}

extension Catalog {
    func recursiveStatus(key: UUID) throws -> RecursiveDeleteStatus? {
        try database.statement("""
            SELECT root_id,phase,total_nodes,removed_nodes,blocked_nodes,request_context,
                root_path,root_index,root_created,parent_path,parent_index,parent_created
            FROM recursive_deletes WHERE operation_key = ?
            """, [.text(key.uuidString)]) { statement in
                guard try statement.step() else { return nil }
                guard let phase = RecursiveDeleteStatus.Phase(rawValue: statement.text(1)) else {
                    throw CatalogError.invalidEntry
                }
                let context: Data?
                if let text = statement.optionalText(5) {
                    guard text.utf8.count <= 43_692, let decoded = Data(base64Encoded: text) else {
                        throw CatalogError.invalidEntry
                    }
                    try SQLiteConnection.validateDomainArchive(decoded)
                    context = decoded
                } else { context = nil }
                guard let rootIndex = UInt64(statement.text(7)), let rootCreated = UInt64(statement.text(8)),
                      let parentIndex = UInt64(statement.text(10)), let parentCreated = UInt64(statement.text(11)) else {
                    throw CatalogError.invalidEntry
                }
                let scope = RecursiveDeleteScope(rootPath: statement.text(6),
                    rootIdentity: .init(indexNumber: rootIndex, createdFiletime: rootCreated),
                    parentPath: statement.text(9), parentIdentity: .init(indexNumber: parentIndex, createdFiletime: parentCreated))
                return RecursiveDeleteStatus(
                    key: key, rootID: statement.text(0), phase: phase, totalNodes: statement.integer(2),
                    removedNodes: statement.integer(3), blockedNodes: statement.integer(4), requestContext: context,
                    domainVersionState: try database.domainVersionState(), scope: scope)
            }
    }

    func requireRecursiveStatus(_ key: UUID) throws -> RecursiveDeleteStatus {
        guard let result = try recursiveStatus(key: key) else { throw CatalogError.invalidTransition }
        return result
    }

    func deleteContextEpoch(_ context: String?) throws -> Int64? {
        guard let context else { return nil }
        guard let id = UUID(uuidString: context), context == id.uuidString.lowercased() else {
            throw CatalogError.invalidEntry
        }
        return try database.statement("SELECT epoch FROM domain_versions WHERE context_id = ?", [.text(context)]) {
            try $0.step() ? $0.integer(0) : nil
        }
    }

    func priorRecursiveDelete(rootID: String, contextEpoch: Int64?) throws -> RecursiveDeleteStatus? {
        if let contextEpoch, let exact = try database.statement("""
            SELECT operation_key FROM recursive_deletes WHERE root_id = ? AND context_epoch = ?
            ORDER BY rowid LIMIT 1
            """, [.text(rootID), .integer(contextEpoch)], { try $0.step() ? $0.text(0) : nil }) {
            guard let key = UUID(uuidString: exact) else { throw CatalogError.invalidEntry }
            return try requireRecursiveStatus(key)
        }
        let previous = try database.statement("""
            SELECT operation_key,fence_epoch FROM recursive_deletes WHERE root_id = ? ORDER BY rowid LIMIT 1
            """, [.text(rootID)]) { try $0.step() ? ($0.text(0), $0.integer(1)) : nil }
        guard let previous else { return nil }
        let latestFence = try database.scalarInt(
            "SELECT max(fence_epoch) FROM recursive_deletes WHERE root_id = ?", [.text(rootID)])
        // Unknown authority always reuses the earliest, smallest established
        // scope, even if a newer explicit callback already created another one.
        if let contextEpoch, contextEpoch > latestFence { return nil }
        guard let key = UUID(uuidString: previous.0) else { throw CatalogError.invalidEntry }
        return try requireRecursiveStatus(key)
    }

    func insertDeleteNode(key: UUID, item: CatalogItem, path: String, depth: Int, parent: RemoteObjectIdentity) throws {
        guard (0...128).contains(depth), let parentID = item.parentID,
              item.entry.kind == .file || item.entry.kind == .directory else { throw CatalogError.invalidEntry }
        try Self.validateMutationPath(path)
        try Self.requireDeleteIdentity(item.entry.objectIdentity)
        try Self.requireDeleteIdentity(parent)
        let encoded = try JSONEncoder().encode(item.entry)
        guard encoded.count <= 65_536 else { throw CatalogError.invalidEntry }
        var digest = MutationFingerprint()
        digest.add("mydrive-recursive-child-v1"); digest.add(key.uuidString.lowercased()); digest.add(item.id)
        let hex = digest.digest
        let raw = Array(hex.prefix(32))
        let uuid = String(raw[0..<8]) + "-" + String(raw[8..<12]) + "-" + String(raw[12..<16])
            + "-" + String(raw[16..<20]) + "-" + String(raw[20..<32])
        try database.execute("""
            INSERT INTO recursive_delete_nodes(operation_key,item_id,parent_id,name,path,kind,depth,
                observation,parent_index,parent_created,child_operation_key,captured)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(key.uuidString), .text(item.id), .text(parentID), .text(item.entry.name), .text(path),
                  .text(item.entry.kind.rawValue), .integer(Int64(depth)), .text(String(decoding: encoded, as: UTF8.self)),
                  .text(String(parent.indexNumber)), .text(String(parent.createdFiletime)), .text(uuid.uppercased()),
                  .integer(item.entry.kind == .directory ? 0 : 1)])
    }

    func deleteNode(key: UUID, id: String) throws -> DeleteNode? {
        try database.statement("SELECT \(Self.deleteNodeColumns) FROM recursive_delete_nodes AS node WHERE operation_key = ? AND item_id = ?",
                               [.text(key.uuidString), .text(id)]) {
            try $0.step() ? Self.decodeDeleteNode($0) : nil
        }
    }

    func deleteNodes(key: UUID, condition: String, limit: Int) throws -> [DeleteNode] {
        try database.statement("""
            SELECT \(Self.deleteNodeColumns) FROM recursive_delete_nodes AS node
            WHERE operation_key = ? AND \(condition) ORDER BY depth DESC,item_id LIMIT ?
            """, [.text(key.uuidString), .integer(Int64(limit))]) { statement in
                var result: [DeleteNode] = []
                while try statement.step() { result.append(try Self.decodeDeleteNode(statement)) }
                return result
            }
    }

    static func requireDeleteIdentity(_ identity: RemoteObjectIdentity?) throws {
        guard let identity, identity.indexNumber != 0, identity.createdFiletime != 0 else {
            throw CatalogError.invalidEntry
        }
    }

    static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    static func exactEntry(_ a: RemoteEntry, _ b: RemoteEntry) -> Bool {
        var left = MutationFingerprint(); left.add(a)
        var right = MutationFingerprint(); right.add(b)
        return left.digest == right.digest
    }

    private static let deleteNodeColumns = "item_id,parent_id,observation,path,depth,parent_index,parent_created,child_operation_key,captured,removed,blocked_code"

    private static func decodeDeleteNode(_ row: SQLStatement) throws -> DeleteNode {
        let json = row.text(2)
        guard json.utf8.count <= 65_536, let index = UInt64(row.text(5)), let created = UInt64(row.text(6)),
              let key = UUID(uuidString: row.text(7)) else { throw CatalogError.invalidEntry }
        let entry = try JSONDecoder().decode(RemoteEntry.self, from: Data(json.utf8))
        try requireDeleteIdentity(entry.objectIdentity)
        return DeleteNode(item: CatalogItem(id: row.text(0), parentID: row.text(1), entry: entry),
                          path: row.text(3), depth: Int(row.integer(4)),
                          parentIdentity: RemoteObjectIdentity(indexNumber: index, createdFiletime: created),
                          operationKey: key, captured: row.integer(8) != 0, removed: row.integer(9) != 0,
                          blockedCode: row.optionalText(10))
    }
}
