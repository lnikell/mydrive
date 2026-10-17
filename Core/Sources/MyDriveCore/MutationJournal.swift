import Foundation

extension Catalog {
    /// Cleanup must retain failed and unknown states too. Replay scheduling's
    /// narrower set is not evidence that local recovery data is disposable.
    public func hasUnfinishedMutations() throws -> Bool {
        try database.scalarInt("SELECT EXISTS(SELECT 1 FROM operations WHERE state != 'completed')") != 0
    }

    /// A repeated identical intent returns the existing operation. Reusing its
    /// idempotency key for different work fails instead of creating ambiguity.
    public func enqueue(_ intent: JournalIntent) throws -> JournalOperation {
        return try database.transaction {
            try enqueueInTransaction(intent)
        }
    }

    func enqueueInTransaction(_ intent: JournalIntent) throws -> JournalOperation {
        if let existing = try operation(key: intent.idempotencyKey) {
            guard existing.intent.requestFingerprint == intent.requestFingerprint else {
                throw CatalogError.idempotencyConflict
            }
            return existing
    }
    if let existing = try operation(requestFingerprint: intent.requestFingerprint) { return existing }
    try validateIntent(intent)
    let encoded = try JSONEncoder().encode(intent)
    guard encoded.count <= 131_072 else { throw CatalogError.invalidEntry }
    let json = String(decoding: encoded, as: UTF8.self)
    try database.execute("""
        INSERT INTO operations(idempotency_key, item_id, intent, state, request_fingerprint)
        VALUES (?, ?, ?, 'queued', ?)
        """, [.text(intent.idempotencyKey.uuidString), .text(intent.itemID), .text(json),
              .text(intent.requestFingerprint)])
    return JournalOperation(intent: intent, state: .queued, attemptCount: 0)
    }

    /// Compare-and-transition prevents an old callback from overwriting newer
    /// state. Repeating a transition that already reached its target is harmless.
    @discardableResult
    public func transitionOperation(
        key: UUID, from expected: JournalState, to target: JournalState
    ) throws -> JournalOperation {
        try database.transaction {
            guard let current = try operation(key: key) else { throw CatalogError.invalidTransition }
            if current.state == target { return current }
            guard current.state == expected, expected.permits(target) else { throw CatalogError.invalidTransition }
            try database.execute("""
                UPDATE operations SET state = ?, attempt_count = attempt_count + ? WHERE idempotency_key = ?
                """, [.text(target.rawValue), .integer(target == .executing ? 1 : 0), .text(key.uuidString)])
            return JournalOperation(
                intent: current.intent, state: target,
                attemptCount: current.attemptCount + (target == .executing ? 1 : 0))
        }
    }

    /// The coordinator invokes this only after obtaining exclusive domain
    /// ownership. Executing operations need remote reconciliation before retry.
    public func recoverInterruptedOperations() throws {
        try database.execute("UPDATE operations SET state = 'uncertain' WHERE state = 'executing'")
    }

    public func replayableOperations(limit: Int = 128) throws -> [JournalOperation] {
        try Self.validatePageSize(limit)
        return try database.statement("""
            SELECT intent, state, attempt_count FROM operations
            WHERE state IN ('queued', 'executing', 'uncertain') ORDER BY sequence LIMIT ?
            """, [.integer(Int64(limit))]) { statement in
                var operations: [JournalOperation] = []
                while try statement.step() { operations.append(try Self.decodeOperation(statement)) }
                return operations
            }
    }

    public func operation(key: UUID) throws -> JournalOperation? {
        try database.statement(
            "SELECT intent, state, attempt_count FROM operations WHERE idempotency_key = ?", [.text(key.uuidString)]
        ) {
            try $0.step() ? Self.decodeOperation($0) : nil
        }
    }

    public func operation(requestFingerprint: String) throws -> JournalOperation? {
        try database.statement("""
            SELECT intent, state, attempt_count FROM operations WHERE request_fingerprint = ?
            """, [.text(requestFingerprint)]) { try $0.step() ? Self.decodeOperation($0) : nil }
    }

    /// A File Provider create-template retry always receives the original ID,
    /// including after a process restart or after the created item was deleted.
    public func providerID(forCreateTemplate templateID: String) throws -> String {
        guard !templateID.isEmpty, templateID.utf8.count <= 4_096, !templateID.contains("\0") else {
            throw CatalogError.invalidEntry
        }
        return try database.transaction {
            if let id = try database.statement(
                "SELECT item_id FROM create_bindings WHERE template_id = ?", [.text(templateID)],
                { try $0.step() ? $0.text(0) : nil }) { return id }
            let id = UUID().uuidString.lowercased()
            try database.execute("INSERT INTO create_bindings(template_id, item_id) VALUES (?, ?)",
                                 [.text(templateID), .text(id)])
            return id
        }
    }

    private func validateIntent(_ intent: JournalIntent) throws {
        guard intent.itemID != Self.rootID else { throw CatalogError.invalidTransition }
        try Self.validateMutationID(intent.itemID)
        if let path = intent.sourcePath { try Self.validateMutationPath(path) }
        if let path = intent.destinationPath { try Self.validateMutationPath(path) }
        if let payload = intent.payload {
            guard payload.size >= 0, payload.sha256.utf8.count == 64,
                  payload.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw CatalogError.invalidEntry
            }
        }
        if let base = intent.baseEntry {
            try Self.validateMutationEntry(base)
            guard intent.expectedVersion.map({ Self.exact($0, base.contentVersion) }) == true,
                  intent.expectedMetadataVersion.map({ Self.exact($0, base.metadataVersion) }) ?? true else {
                throw CatalogError.invalidEntry
            }
        }
        switch intent.action {
        case .create(let parentID, let name, let kind):
            try Self.validateName(name)
            try requireDirectory(parentID)
            guard try item(id: intent.itemID) == nil,
                  kind == .directory ? intent.payload == nil : kind == .file && intent.payload != nil,
                  intent.expectedVersion == nil, intent.expectedMetadataVersion == nil,
                  intent.baseEntry == nil else { throw CatalogError.invalidEntry }
            if let template = intent.createTemplateID {
                let bound = try database.statement(
                    "SELECT item_id FROM create_bindings WHERE template_id = ?", [.text(template)],
                    { try $0.step() ? $0.text(0) : nil })
                guard bound == intent.itemID else { throw CatalogError.idempotencyConflict }
            }
            return
        case .update(let parentID, let name):
            try Self.validateName(name)
            try requireDirectory(parentID)
        case .rename(let name):
            try Self.validateName(name)
            guard intent.payload == nil else { throw CatalogError.invalidEntry }
        case .move(let parentID, let name):
            try Self.validateName(name)
            try requireDirectory(parentID)
            guard intent.payload == nil else { throw CatalogError.invalidEntry }
        case .delete, .deleteTree:
            guard intent.payload == nil else { throw CatalogError.invalidEntry }
        }
        guard intent.createTemplateID == nil else { throw CatalogError.invalidEntry }
        guard let item = try item(id: intent.itemID), !item.isDeleted else {
            throw CatalogError.missingItem(intent.itemID)
        }
        if intent.payload != nil, item.entry.kind != .file { throw CatalogError.invalidEntry }
        if case .deleteTree = intent.action {
            guard item.entry.kind == .directory, intent.sourcePath != nil, intent.baseEntry != nil,
                  intent.destinationPath == nil else { throw CatalogError.invalidEntry }
        } else if intent.deletionContextID != nil { throw CatalogError.invalidEntry }
    }

    static func validateMutationID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 4_096, !id.contains("\0") else { throw CatalogError.invalidEntry }
    }

    static func validateMutationPath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 65_536, !path.contains("\0"), !path.contains("\\") else {
            throw CatalogError.invalidEntry
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            try validateName(String(component))
        }
    }

    static func validateMutationEntry(_ entry: RemoteEntry) throws {
        try validateName(entry.name)
        guard entry.size >= 0, entry.remoteKey != "",
              entry.modifiedAt?.timeIntervalSince1970.isFinite != false else { throw CatalogError.invalidEntry }
    }

    private static func decodeOperation(_ statement: SQLStatement) throws -> JournalOperation {
        guard let state = JournalState(rawValue: statement.text(1)) else { throw CatalogError.invalidEntry }
        let intent = try JSONDecoder().decode(JournalIntent.self, from: Data(statement.text(0).utf8))
        return JournalOperation(intent: intent, state: state, attemptCount: statement.integer(2))
    }
}
