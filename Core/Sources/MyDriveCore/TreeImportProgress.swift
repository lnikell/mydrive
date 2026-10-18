import Foundation

extension Catalog {
    /// The callback driver supplies verified outcomes, not requested state. Each
    /// receipt and child-journal completion share one FULL SQLite transaction.
    /// Only publication of the verified payload root exposes the complete tree.
    public func recordTreeImportProgress(key: UUID, update: TreeImportProgress) throws -> TreeImportStatus {
        try database.transaction {
            let record = try importRecord(key)
            try requireImportLayout(record)
            guard record.status.phase == .frozen || record.status.phase == .published else { throw CatalogError.invalidTransition }
            switch update {
            case .committed(let step, let childKey, let entry, let sha256, let evidence):
                try recordImportCommit(record, step: step, childKey: childKey, entry: entry,
                                       sha256: sha256, contentEvidence: evidence)
            case .fileVerified(let id, let entry, let sha256):
                guard record.status.phase == .frozen, let node = try importNode(key, id: id),
                      let payload = node.spec.payload, let placed = node.placed,
                      Self.exactEntry(entry, placed), Self.exact(sha256, payload.sha256), entry.size == payload.size else {
                    throw CatalogError.invalidEntry
                }
                try verifyImportNode(node, key: key, entry: entry)
            case .directoryPage(let id, let scan, let entries):
                try recordImportDirectoryPage(record, id: id, scan: scan, entries: entries)
            case .directoryComplete(let id, let scan, let entry):
                guard record.status.phase == .frozen, let node = try importNode(key, id: id),
                      node.spec.kind == .directory, node.verificationScan == scan.uuidString,
                      let placed = node.placed else { throw CatalogError.invalidTransition }
                try validateImportObservation(entry, kind: .directory, name: placed.name, identity: placed.objectIdentity)
                guard try database.scalarInt("""
                    SELECT EXISTS(SELECT 1 FROM tree_import_nodes WHERE operation_key = ? AND parent_path = ?
                        AND (verified_entry IS NULL OR seen_scan IS NOT ?))
                    """, [.text(key.uuidString), .text(node.spec.path), .text(scan.uuidString)]) == 0 else {
                    throw CatalogError.invalidEntry
                }
                try verifyImportNode(node, key: key, entry: entry)
            case .blocked(let code):
                guard record.status.phase == .frozen, (1...256).contains(code.utf8.count), !code.contains("\0") else {
                    throw CatalogError.invalidEntry
                }
                try database.execute("UPDATE tree_imports SET blocked_code = ? WHERE operation_key = ?", [.text(code), .text(key.uuidString)])
            }
            return try importRecord(key).status
        }
    }

    func recordImportCommit(_ record: ImportRecord, step: TreeImportStep, childKey: UUID,
                            entry: RemoteEntry, sha256: String?, contentEvidence: MutationContentEvidence?) throws {
        let status = record.status
        let node: ImportNode?
        let expectedKey: UUID
        switch step {
        case .arena: node = nil; expectedKey = record.arenaKey
        case .publish: node = try importNode(status.key, path: ""); expectedKey = record.publishKey
        case .create, .place:
            let column = step == .create ? "create_operation_key" : "place_operation_key"
            node = try database.statement("""
                SELECT \(Self.importNodeColumns) FROM tree_import_nodes AS node
                WHERE node.operation_key = ? AND node.\(column) = ?
                """, [.text(status.key.uuidString), .text(childKey.uuidString)]) { try $0.step() ? Self.decodeImportNode($0) : nil }
            guard let found = node else { throw CatalogError.invalidTransition }
            expectedKey = step == .create ? found.createKey : found.placeKey
        }
        guard childKey == expectedKey, let operation = try operation(key: childKey) else { throw CatalogError.invalidTransition }
        let work = try importMutationWork(record, step: step, node: node)
        guard case .mutation(_, let expected, _, _) = work,
              Self.exact(expected.requestFingerprint, operation.intent.requestFingerprint) else { throw CatalogError.idempotencyConflict }
        try Self.validateContentEvidence(contentEvidence, intent: operation.intent)
        if operation.intent.saveContract != nil, sha256 != nil { throw CatalogError.invalidEntry }
        if let receipt = try mutationResult(key: childKey) {
            guard receipt.items.count == 1, Self.exactEntry(receipt.items[0].entry, entry),
                  receipt.contentEvidence == contentEvidence,
                  (step != .create || operation.intent.saveContract != nil || node?.spec.payload?.sha256 == sha256) else {
                throw CatalogError.idempotencyConflict
            }
            return
        }
        guard status.phase == .frozen, operation.state == .executing || operation.state == .uncertain else {
            throw CatalogError.invalidTransition
        }
        switch step {
        case .arena:
            try validateImportObservation(entry, kind: .directory, name: status.scope.arenaName)
            guard sha256 == nil, let root = try importNode(status.key, path: ""),
                  root.spec.kind == .directory, root.itemID == record.arenaID else { throw CatalogError.invalidEntry }
            try database.execute("UPDATE tree_imports SET arena_entry = ?, blocked_code = NULL WHERE operation_key = ?",
                                 [.text(try Self.treeEncode(entry)), .text(status.key.uuidString)])
            try database.execute("UPDATE tree_import_nodes SET created_entry = ?, placed_entry = ? WHERE operation_key = ? AND path = ''",
                                 [.text(try Self.treeEncode(entry)), .text(try Self.treeEncode(entry)), .text(status.key.uuidString)])
        case .create:
            guard let node else { throw CatalogError.invalidTransition }
            try validateImportObservation(entry, kind: node.spec.kind, name: Self.treeName(node.scratchPath))
            if let payload = node.spec.payload {
                guard (operation.intent.saveContract != nil || Self.exact(sha256 ?? "", payload.sha256)),
                      entry.size == payload.size else { throw CatalogError.invalidEntry }
            } else if sha256 != nil { throw CatalogError.invalidEntry }
            try database.execute("UPDATE tree_import_nodes SET created_entry = ? WHERE operation_key = ? AND path = ?",
                                 [.text(try Self.treeEncode(entry)), .text(status.key.uuidString), .text(node.spec.path)])
        case .place:
            guard let node, let created = node.created, sha256 == nil else { throw CatalogError.invalidTransition }
            let name = node.spec.path.isEmpty ? "payload" : Self.treeName(node.spec.path)
            try validateImportObservation(entry, kind: node.spec.kind, name: name, identity: created.objectIdentity)
            guard node.spec.payload.map({ $0.size == entry.size }) ?? true else { throw CatalogError.invalidEntry }
            try database.execute("UPDATE tree_import_nodes SET placed_entry = ? WHERE operation_key = ? AND path = ?",
                                 [.text(try Self.treeEncode(entry)), .text(status.key.uuidString), .text(node.spec.path)])
        case .publish:
            guard let node, let verified = node.verified, sha256 == nil else { throw CatalogError.invalidTransition }
            try validateImportObservation(entry, kind: .directory, name: status.filename, identity: verified.objectIdentity)
            try publishImport(record, root: entry)
        }
        // Private child receipts describe verified remote scratch/payload
        // objects. They never insert items or emit a Catalog change event.
        let receiptItem = CatalogItem(id: operation.intent.itemID, parentID: importReceiptParent(operation.intent), entry: entry)
        var fingerprint = MutationFingerprint()
        fingerprint.add("mydrive-tree-receipt-v1"); fingerprint.add(step.rawValue); fingerprint.add(entry); fingerprint.add(sha256)
        fingerprint.addContentEvidence(contentEvidence)
        try storeMutationResult(.init(items: [receiptItem], tombstones: [], generation: try generation(),
                                      contentEvidence: contentEvidence),
                                key: childKey, fingerprint: fingerprint.digest)
    }

    private func importReceiptParent(_ intent: JournalIntent) -> String? {
        switch intent.action {
        case .create(let parent, _, _), .move(let parent, _): parent
        default: nil
        }
    }

    private func recordImportDirectoryPage(_ record: ImportRecord, id: String, scan: UUID, entries: [RemoteEntry]) throws {
        guard entries.count <= 1_000 else { throw CatalogError.invalidPageSize }
        guard record.status.phase == .frozen, let parent = try importNode(record.status.key, id: id),
              parent.spec.kind == .directory, parent.verified == nil, parent.verificationScan == scan.uuidString else {
            throw CatalogError.invalidTransition
        }
        for entry in entries {
            try Self.validateMutationEntry(entry)
            let path = Self.treeJoin(parent.spec.path, entry.name)
            guard let node = try importNode(record.status.key, path: path), node.parentPath.map({ Self.exact($0, parent.spec.path) }) == true,
                  let verified = node.verified, Self.exactEntry(entry, verified),
                  try database.scalarText("SELECT COALESCE(seen_scan,'') FROM tree_import_nodes WHERE operation_key = ? AND path = ?",
                                          [.text(record.status.key.uuidString), .text(path)]) != scan.uuidString else {
                throw CatalogError.invalidEntry
            }
            try database.execute("UPDATE tree_import_nodes SET seen_scan = ? WHERE operation_key = ? AND path = ?",
                                 [.text(scan.uuidString), .text(record.status.key.uuidString), .text(path)])
        }
    }

    private func verifyImportNode(_ node: ImportNode, key: UUID, entry: RemoteEntry) throws {
        if let previous = node.verified {
            guard Self.exactEntry(previous, entry) else { throw CatalogError.idempotencyConflict }
            return
        }
        try database.execute("UPDATE tree_import_nodes SET verified_entry = ? WHERE operation_key = ? AND path = ?",
                             [.text(try Self.treeEncode(entry)), .text(key.uuidString), .text(node.spec.path)])
        try database.execute("UPDATE tree_imports SET verified_nodes = verified_nodes + 1, blocked_code = NULL WHERE operation_key = ?",
                             [.text(key.uuidString)])
    }
}
