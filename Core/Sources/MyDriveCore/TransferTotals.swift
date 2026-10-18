import Foundation

public struct DailyTransferTotals: Codable, Equatable, Sendable {
    public var files: Int64 = 0
    public var uploaded: Int64 = 0
    public var downloaded: Int64 = 0
    public init() {}
}

extension Catalog {
    /// A retried native callback for the same verified content is counted once
    /// per direction/day. Counters survive history clearing and provider restart.
    public func recordTransfer(itemID: String, version: String, upload: Bool, bytes: Int64, date: Date = Date()) throws {
        guard bytes >= 0, !itemID.isEmpty, !version.isEmpty, itemID.utf8.count <= 128, version.utf8.count <= 512,
              date.timeIntervalSinceReferenceDate.isFinite else { throw CatalogError.invalidEntry }
        let day = Self.transferDay(date)
        try database.transaction {
            try addTransfer(itemID: itemID, version: version, upload: upload, bytes: bytes, day: day)
            try pruneTransferTotals(date: date)
        }
    }

    /// Count children only after their complete folder becomes visible. All
    /// receipts share one transaction and bounded manifest pages; retries of
    /// the native root callback cannot count the same file twice.
    public func recordPublishedTreeTransfers(rootID: String, date: Date = Date()) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw CatalogError.invalidEntry }
        guard let status = try treeImportStatus(rootID: rootID) else { return }
        guard status.phase == .published, status.layoutVersion == 2 else { throw CatalogError.invalidTransition }
        let day = Self.transferDay(date)
        try database.transaction {
            var cursor = ""
            while true {
                let page: [ImportNode] = try database.statement("""
                    SELECT \(Self.importNodeColumns) FROM tree_import_nodes AS node
                    WHERE node.operation_key = ? AND node.path > ? AND node.kind = 'file'
                    ORDER BY node.path COLLATE BINARY LIMIT 128
                    """, [.text(status.key.uuidString), .text(cursor)]) { row in
                        var page: [ImportNode] = []
                        while try row.step() { page.append(try Self.decodeImportNode(row)) }
                        return page
                    }
                for node in page {
                    guard let payload = node.spec.payload, let verified = node.verified,
                          verified.size == payload.size else { throw CatalogError.invalidTransition }
                    try addTransfer(itemID: node.itemID, version: verified.contentVersion, upload: true,
                                    bytes: payload.size, day: day)
                }
                guard let last = page.last else { break }
                cursor = last.spec.path
            }
            try pruneTransferTotals(date: date)
        }
    }

    private func addTransfer(itemID: String, version: String, upload: Bool, bytes: Int64, day: String) throws {
        guard bytes >= 0, !itemID.isEmpty, !version.isEmpty, itemID.utf8.count <= 128, version.utf8.count <= 512 else {
            throw CatalogError.invalidEntry
        }
        try database.execute("INSERT OR IGNORE INTO transfer_receipts(day, item_id, version, upload) VALUES (?, ?, ?, ?)",
                [.text(day), .text(itemID), .text(version), .integer(upload ? 1 : 0)])
            guard try database.scalarInt("SELECT changes()") > 0 else { return }
            try database.execute("""
                INSERT INTO transfer_totals(day, files, uploaded, downloaded) VALUES (?, 1, ?, ?)
                ON CONFLICT(day) DO UPDATE SET
                    files = CASE WHEN files = 9223372036854775807 THEN files ELSE files + 1 END,
                    uploaded = CASE WHEN uploaded > 9223372036854775807 - excluded.uploaded
                        THEN 9223372036854775807 ELSE uploaded + excluded.uploaded END,
                    downloaded = CASE WHEN downloaded > 9223372036854775807 - excluded.downloaded
                        THEN 9223372036854775807 ELSE downloaded + excluded.downloaded END
                """, [.text(day), .integer(upload ? bytes : 0), .integer(upload ? 0 : bytes)])
    }

    private func pruneTransferTotals(date: Date) throws {
        let cutoff = Self.transferDay(date.addingTimeInterval(-8 * 86400))
        try database.execute("DELETE FROM transfer_receipts WHERE day < ?", [.text(cutoff)])
        try database.execute("DELETE FROM transfer_totals WHERE day < ?", [.text(cutoff)])
    }

    public func transferTotals(date: Date = Date()) throws -> DailyTransferTotals {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw CatalogError.invalidEntry }
        return try database.statement("SELECT files, uploaded, downloaded FROM transfer_totals WHERE day = ?", [.text(Self.transferDay(date))]) {
            var totals = DailyTransferTotals()
            if try $0.step() { totals.files = $0.integer(0); totals.uploaded = $0.integer(1); totals.downloaded = $0.integer(2) }
            return totals
        }
    }

    private static func transferDay(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
