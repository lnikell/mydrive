import Foundation

extension Catalog {
    /// A repeated identical intent returns the existing operation. Reusing its
    /// idempotency key for different work fails instead of creating ambiguity.
    public func enqueue(_ intent: JournalIntent) throws -> JournalOperation {
        try validateIntent(intent)
        return try database.transaction {
            if let existing = try operation(key: intent.idempotencyKey) {
                guard existing.intent == intent else { throw CatalogError.idempotencyConflict }
                return existing
            }
            guard try item(id: intent.itemID) != nil else { throw CatalogError.missingItem(intent.itemID) }
            let encoded = try JSONEncoder().encode(intent)
            let json = String(decoding: encoded, as: UTF8.self)
            try database.execute("""
                INSERT INTO operations(idempotency_key, item_id, intent, state) VALUES (?, ?, ?, 'queued')
                """, [.text(intent.idempotencyKey.uuidString), .text(intent.itemID), .text(json)])
            return JournalOperation(intent: intent, state: .queued, attemptCount: 0)
        }
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

    private func validateIntent(_ intent: JournalIntent) throws {
        guard intent.itemID != Self.rootID else { throw CatalogError.invalidTransition }
        switch intent.action {
        case .rename(let name): try Self.validateName(name)
        case .move(let parentID, let name):
            try Self.validateName(name)
            try requireDirectory(parentID)
        case .delete: break
        }
    }

    private static func decodeOperation(_ statement: SQLStatement) throws -> JournalOperation {
        guard let state = JournalState(rawValue: statement.text(1)) else { throw CatalogError.invalidEntry }
        let intent = try JSONDecoder().decode(JournalIntent.self, from: Data(statement.text(0).utf8))
        return JournalOperation(intent: intent, state: state, attemptCount: statement.integer(2))
    }
}
