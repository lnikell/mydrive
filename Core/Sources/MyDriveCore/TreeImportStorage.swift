import Foundation

struct ImportRecord {
    let status: TreeImportStatus
    let arenaID: String
    let arenaKey: UUID
    let publishKey: UUID
}

struct ImportNode {
    let spec: TreeImportEntry
    let itemID: String
    let parentID: String
    let parentPath: String?
    let depth: Int
    let sealed: Bool
    let scratchPath: String
    let createKey: UUID
    let placeKey: UUID
    let created: RemoteEntry?
    let placed: RemoteEntry?
    let verified: RemoteEntry?
    let verificationScan: String?

    func item(_ entry: RemoteEntry) -> CatalogMutationItem {
        .init(id: itemID, parentID: parentID, entry: entry)
    }
}

extension Catalog {
    func importOwnerKey(_ operationKey: UUID) throws -> UUID? {
        try database.statement("""
            SELECT operation_key FROM tree_imports
                WHERE operation_key = ? OR arena_operation_key = ? OR publish_operation_key = ?
            UNION
            SELECT operation_key FROM tree_import_nodes WHERE create_operation_key = ? OR place_operation_key = ?
            LIMIT 2
            """, Array(repeating: .text(operationKey.uuidString), count: 5)) { row in
                guard try row.step() else { return nil }
                guard let owner = UUID(uuidString: row.text(0)), try !row.step() else {
                    throw CatalogError.invalidTransition
                }
                return owner
            }
    }

    static func validateTreeEntry(_ entry: TreeImportEntry) throws {
        if !entry.path.isEmpty { try validateTreePath(entry.path) }
        guard entry.kind == .directory ? entry.payload == nil : entry.kind == .file && entry.payload != nil else {
            throw CatalogError.invalidEntry
        }
        if let payload = entry.payload { try validateTreePayload(payload) }
    }

    static func validateTreePayload(_ payload: StagedPayload) throws {
        guard payload.size >= 0, validTreeHash(payload.sha256) else { throw CatalogError.invalidEntry }
    }

    static func validTreeHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validateTreePath(_ path: String, empty: Bool = false) throws {
        if empty && path.isEmpty { return }
        try validateMutationPath(path)
        guard path.utf8.count <= 4_096,
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ $0.utf8.count <= 255 }) else {
            throw CatalogError.invalidEntry
        }
    }

    static func treeJoin(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }
    static func treeParent(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
    }
    static func treeName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? "" }

    static func treeID(_ rootID: String, _ path: String) -> String {
        if path.isEmpty { return rootID }
        var hash = MutationFingerprint()
        hash.add("mydrive-tree-item-v1"); hash.add(rootID); hash.add(path)
        return String(hash.digest.prefix(32))
    }

    static func treeKey(_ rootKey: UUID, _ purpose: String, _ path: String = "") -> UUID {
        var hash = MutationFingerprint()
        hash.add("mydrive-tree-operation-v1"); hash.add(rootKey.uuidString.lowercased()); hash.add(purpose); hash.add(path)
        let hex = Array(hash.digest.prefix(32))
        let text = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-" + String(hex[12..<16])
            + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32])
        return UUID(uuidString: text)!
    }

    static func treeEncode<T: Encodable>(_ value: T, limit: Int = 65_536) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw CatalogError.invalidEntry }
        return String(decoding: data, as: UTF8.self)
    }

    static func treeDecode<T: Decodable>(_ type: T.Type, _ text: String, limit: Int = 65_536) throws -> T {
        guard text.utf8.count <= limit else { throw CatalogError.invalidEntry }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    func importRecord(_ key: UUID) throws -> ImportRecord {
        try database.statement("""
            SELECT tree_id,node_count,total_bytes,digest,root_id,parent_id,filename,phase,
                parent_path,parent_index,parent_created,arena_name,arena_id,arena_operation_key,publish_operation_key,
                arena_entry,verified_nodes,blocked_code
            FROM tree_imports WHERE operation_key = ?
            """, [.text(key.uuidString)]) { row in
                guard try row.step(), let treeID = UUID(uuidString: row.text(0)),
                      let phase = TreeImportStatus.Phase(rawValue: row.text(7)),
                      let index = UInt64(row.text(9)), let created = UInt64(row.text(10)),
                      let arenaKey = UUID(uuidString: row.text(13)), let publishKey = UUID(uuidString: row.text(14)) else {
                    throw CatalogError.invalidTransition
                }
                let scope = TreeImportScope(parentPath: row.text(8),
                    parentIdentity: .init(indexNumber: index, createdFiletime: created), arenaName: row.text(11))
                let arenaPath = Self.treeJoin(scope.parentPath, scope.arenaName)
                return ImportRecord(status: TreeImportStatus(key: key,
                    tree: .init(id: treeID, nodeCount: row.integer(1), totalBytes: row.integer(2), sha256: row.text(3)),
                    rootID: row.text(4), parentID: row.text(5), filename: row.text(6), phase: phase, scope: scope,
                    arenaPath: arenaPath, payloadPath: Self.treeJoin(arenaPath, "payload"),
                    destinationPath: Self.treeJoin(scope.parentPath, row.text(6)),
                    arena: try row.optionalText(15).map { try Self.treeDecode(RemoteEntry.self, $0) },
                    verifiedNodes: row.integer(16), blockedCode: row.optionalText(17), result: try mutationResult(key: key)),
                    arenaID: row.text(12), arenaKey: arenaKey, publishKey: publishKey)
            }
    }

    static let importNodeColumns = "node.path,node.parent_path,node.kind,node.payload,node.item_id,node.parent_id,node.depth,node.sealed,node.scratch_path,node.create_operation_key,node.place_operation_key,node.created_entry,node.placed_entry,node.verified_entry,node.verification_scan"

    static func decodeImportNode(_ row: SQLStatement) throws -> ImportNode {
        guard let kind = ItemKind(rawValue: row.text(2)),
              let create = UUID(uuidString: row.text(9)), let place = UUID(uuidString: row.text(10)) else {
            throw CatalogError.invalidEntry
        }
        let spec = TreeImportEntry(path: row.text(0), kind: kind,
            payload: try row.optionalText(3).map { try treeDecode(StagedPayload.self, $0) })
        try validateTreeEntry(spec)
        return ImportNode(spec: spec, itemID: row.text(4), parentID: row.text(5), parentPath: row.optionalText(1),
            depth: Int(row.integer(6)), sealed: row.integer(7) != 0, scratchPath: row.text(8), createKey: create, placeKey: place,
            created: try row.optionalText(11).map { try treeDecode(RemoteEntry.self, $0) },
            placed: try row.optionalText(12).map { try treeDecode(RemoteEntry.self, $0) },
            verified: try row.optionalText(13).map { try treeDecode(RemoteEntry.self, $0) }, verificationScan: row.optionalText(14))
    }

    func importNode(_ key: UUID, path: String? = nil, id: String? = nil) throws -> ImportNode? {
        let condition = path == nil ? "node.item_id = ?" : "node.path = ?"
        return try database.statement("""
            SELECT \(Self.importNodeColumns) FROM tree_import_nodes AS node
            WHERE node.operation_key = ? AND \(condition)
            """, [.text(key.uuidString), .text(path ?? id ?? "")]) { try $0.step() ? Self.decodeImportNode($0) : nil }
    }

    func qualifyImportParent(_ record: ImportRecord) throws {
        let status = record.status
        try requireDirectory(status.parentID)
        guard let path = try relativePath(id: status.parentID), Self.exact(path, status.scope.parentPath) else {
            throw CatalogError.invalidParent
        }
        if status.parentID != Self.rootID {
            guard try item(id: status.parentID)?.entry.objectIdentity == status.scope.parentIdentity else {
                throw CatalogError.invalidParent
            }
        }
    }

    func validateImportObservation(_ entry: RemoteEntry, kind: ItemKind, name: String,
                                   identity: RemoteObjectIdentity? = nil) throws {
        try Self.validateMutationEntry(entry)
        try Self.requireDeleteIdentity(entry.objectIdentity)
        guard entry.kind == kind, Self.exact(entry.name, name),
              identity == nil || entry.objectIdentity == identity else { throw CatalogError.invalidEntry }
    }
}
