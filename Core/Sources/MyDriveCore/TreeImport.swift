import Foundation

extension Catalog {
    /// A nil-contents callback can recover the original durable source and
    /// completed root receipt without preparing a different logical tree.
    public func treeImportStatus(rootID: String) throws -> TreeImportStatus? {
        try Self.validateMutationID(rootID)
        let key = try database.statement("SELECT operation_key FROM tree_imports WHERE root_id = ?", [.text(rootID)]) {
            try $0.step() ? $0.text(0) : nil
        }
        guard let key else { return nil }
        guard let id = UUID(uuidString: key) else { throw CatalogError.invalidTransition }
        return try importRecord(id).status
    }

    /// Private create/place operations deliberately share the canonical journal,
    /// but their authority comes from this manifest. Generic maintenance must
    /// route them to their tree owner before constructing or invoking any RPC.
    public func treeImportOwner(operationKey: UUID) throws -> TreeImportStatus? {
        guard let key = try importOwnerKey(operationKey) else { return nil }
        return try importRecord(key).status
    }

    /// New trees only. The already-durable local snapshot is immutable before
    /// preparation. A crash replay returns the canonical tree/payload references.
    public func prepareTreeImport(intent: JournalIntent, scope: TreeImportScope) throws -> TreeImportStatus {
        guard let tree = intent.tree, tree.nodeCount > 0, tree.totalBytes >= 0, Self.validTreeHash(tree.sha256),
              intent.payload == nil, intent.baseEntry == nil, intent.expectedVersion == nil,
              intent.expectedMetadataVersion == nil, intent.sourcePath == nil, intent.deletionContextID == nil,
              case .create(let parentID, let name, .directory) = intent.action else { throw CatalogError.invalidEntry }
        try Self.validateMutationID(intent.itemID)
        guard intent.itemID != Self.rootID else { throw CatalogError.invalidEntry }
        try Self.validateTreePath(name); try Self.validateTreePath(scope.arenaName)
        guard !name.contains("/"), !scope.arenaName.contains("/"), !Self.exact(name, scope.arenaName) else {
            throw CatalogError.invalidEntry
        }
        try Self.validateTreePath(scope.parentPath, empty: true)
        try Self.requireDeleteIdentity(scope.parentIdentity)
        let destination = Self.treeJoin(scope.parentPath, name), arena = Self.treeJoin(scope.parentPath, scope.arenaName)
        try Self.validateTreePath(destination); try Self.validateTreePath(arena)
        if let requested = intent.destinationPath, !Self.exact(requested, destination) { throw CatalogError.invalidEntry }
        return try database.transaction {
            if let existing = try matchingOperation(intent) {
                let record = try importRecord(existing.intent.idempotencyKey)
                try requireImportLayout(record)
                return record.status
            }
            try requireDirectory(parentID)
            guard try item(id: intent.itemID) == nil,
                  let path = try relativePath(id: parentID), Self.exact(path, scope.parentPath) else { throw CatalogError.invalidParent }
            if parentID != Self.rootID {
                guard try item(id: parentID)?.entry.objectIdentity == scope.parentIdentity else { throw CatalogError.invalidParent }
            }
            guard try database.scalarInt("SELECT EXISTS(SELECT 1 FROM tree_imports WHERE root_id = ?)", [.text(intent.itemID)]) == 0 else {
                throw CatalogError.idempotencyConflict
            }
            let bound = try intent.createTemplateID.map { template in
                try database.statement("SELECT item_id FROM create_bindings WHERE template_id = ?", [.text(template)]) {
                    try $0.step() ? $0.text(0) : nil
                }
            } ?? nil
            guard bound == intent.itemID else {
                throw CatalogError.idempotencyConflict
            }
            let operation = try insertQualifiedOperation(intent), key = operation.intent.idempotencyKey
            try database.execute("""
                INSERT INTO tree_imports(operation_key,tree_id,node_count,total_bytes,digest,root_id,parent_id,filename,
                    parent_path,parent_index,parent_created,arena_name,arena_id,arena_operation_key,publish_operation_key,layout_version)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,2)
                """, [.text(key.uuidString), .text(tree.id.uuidString), .integer(tree.nodeCount), .integer(tree.totalBytes),
                      .text(tree.sha256), .text(intent.itemID), .text(parentID), .text(name), .text(scope.parentPath),
                      .text(String(scope.parentIdentity.indexNumber)), .text(String(scope.parentIdentity.createdFiletime)),
                      .text(scope.arenaName), .text(intent.itemID),
                      .text(Self.treeKey(key, "arena").uuidString), .text(Self.treeKey(key, "publish").uuidString)])
            return try importRecord(key).status
        }
    }

    /// Bounded intake of the frozen local snapshot. Parents precede children;
    /// sealing a directory prevents later additions. No work is executable until
    /// the entire canonical digest/count has been recomputed successfully.
    public func stageTreeImport(key: UUID, entries: [TreeImportEntry], sealedDirectories: [String] = [],
                                isComplete: Bool = false) throws -> TreeImportStatus {
        guard entries.count + sealedDirectories.count <= 1_000 else { throw CatalogError.invalidPageSize }
        for entry in entries { try Self.validateTreeEntry(entry) }
        return try database.transaction {
            let record = try importRecord(key), status = record.status
            try requireImportLayout(record)
            guard status.phase == .building else { throw CatalogError.invalidTransition }
            var addedCount: Int64 = 0, addedBytes: Int64 = 0
            for entry in entries {
                if let existing = try importNode(key, path: entry.path) {
                    guard Self.exact(existing.spec.path, entry.path), existing.spec.kind == entry.kind,
                          existing.spec.payload == entry.payload else { throw CatalogError.idempotencyConflict }
                    continue
                }
                let parentPath = Self.treeParent(entry.path), depth = entry.path.isEmpty ? 0 : entry.path.split(separator: "/").count
                guard depth <= 128 else { throw CatalogError.invalidEntry }
                let itemID = Self.treeID(status.rootID, entry.path)
                let parentID: String
                if let parentPath {
                    guard let parent = try importNode(key, path: parentPath), parent.spec.kind == .directory, !parent.sealed else {
                        throw CatalogError.invalidParent
                    }
                    parentID = parent.itemID
                } else {
                    guard entry.kind == .directory else { throw CatalogError.invalidEntry }
                    parentID = status.parentID
                }
                guard try item(id: itemID) == nil else { throw CatalogError.invalidEntry }
                let createKey = Self.treeKey(key, "create", entry.path), placeKey = Self.treeKey(key, "place", entry.path)
                let parentTarget = parentPath.map { $0.isEmpty ? status.payloadPath : Self.treeJoin(status.payloadPath, $0) } ?? status.scope.parentPath
                let scratch = entry.path.isEmpty ? status.arenaPath :
                    Self.treeJoin(parentTarget, ".mydrive-" + createKey.uuidString.lowercased() + ".node")
                try Self.validateTreePath(scratch)
                try Self.validateTreePath(entry.path.isEmpty ? status.payloadPath : Self.treeJoin(status.payloadPath, entry.path))
                try database.execute("""
                    INSERT INTO tree_import_nodes(operation_key,path,parent_path,name,kind,item_id,parent_id,depth,payload,
                        scratch_path,create_operation_key,place_operation_key,sealed)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(key.uuidString), .text(entry.path), SQLValue(parentPath), .text(Self.treeName(entry.path)),
                          .text(entry.kind.rawValue), .text(itemID), .text(parentID), .integer(Int64(depth)),
                          try entry.payload.map { .text(try Self.treeEncode($0)) } ?? .null, .text(scratch),
                          .text(createKey.uuidString), .text(placeKey.uuidString), .integer(entry.kind == .file ? 1 : 0)])
                addedCount += 1
                let (nextBytes, overflow) = addedBytes.addingReportingOverflow(entry.payload?.size ?? 0)
                guard !overflow else { throw CatalogError.invalidEntry }
                addedBytes = nextBytes
            }
            let staged = try database.scalarInt("SELECT staged_nodes FROM tree_imports WHERE operation_key = ?", [.text(key.uuidString)])
            let bytes = try database.scalarInt("SELECT staged_bytes FROM tree_imports WHERE operation_key = ?", [.text(key.uuidString)])
            let (nextCount, countOverflow) = staged.addingReportingOverflow(addedCount)
            let (nextBytes, bytesOverflow) = bytes.addingReportingOverflow(addedBytes)
            guard !countOverflow, !bytesOverflow, nextCount <= status.tree.nodeCount, nextBytes <= status.tree.totalBytes else {
                throw CatalogError.invalidEntry
            }
            try database.execute("UPDATE tree_imports SET staged_nodes = ?, staged_bytes = ? WHERE operation_key = ?",
                                 [.integer(nextCount), .integer(nextBytes), .text(key.uuidString)])
            for path in sealedDirectories {
                guard let node = try importNode(key, path: path), node.spec.kind == .directory else {
                    throw CatalogError.invalidEntry
                }
                try database.execute("UPDATE tree_import_nodes SET sealed = 1 WHERE operation_key = ? AND path = ?",
                                     [.text(key.uuidString), .text(path)])
            }
            if isComplete {
                guard try database.scalarInt("SELECT EXISTS(SELECT 1 FROM tree_import_nodes WHERE operation_key = ? AND sealed = 0)",
                                             [.text(key.uuidString)]) == 0 else { throw CatalogError.invalidEntry }
                var digest = TreeImportDigest()
                try database.statement("SELECT \(Self.importNodeColumns) FROM tree_import_nodes AS node WHERE operation_key = ? ORDER BY path",
                                       [.text(key.uuidString)]) { row in
                    while try row.step() { try digest.append(Self.decodeImportNode(row).spec) }
                }
                let actual = try digest.reference(id: status.tree.id)
                guard actual == status.tree else { throw CatalogError.idempotencyConflict }
                try database.execute("UPDATE tree_imports SET phase = 'frozen' WHERE operation_key = ?", [.text(key.uuidString)])
            }
            return try importRecord(key).status
        }
    }
}
