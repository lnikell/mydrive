import Foundation
import MyDriveCore

enum LibraryScope: String, Codable, Sendable { case onlineOnly, keptOffline }

struct LibraryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let folder: Bool
    let size: Int64
    let keptOffline: Bool
    /// Nil means the OS state could not be inspected; it is never guessed.
    let downloaded: Bool?
}

struct LibraryPage: Codable, Sendable {
    let entries: [LibraryEntry]
    let nextID: String?
    let generation: Int64

    func encodedForControl() throws -> Data {
        _ = try validated()
        return try BoundedRecordEncoding.encode(entries, maximumBytes: 2_097_152, keeping: .first) { selected in
            return try JSONEncoder().encode(LibraryPage(entries: selected,
                nextID: selected.count < entries.count ? selected.last?.id : nextID, generation: generation))
        }
    }

    func validated() throws -> Self {
        guard entries.count <= 128, generation >= 0, (nextID?.utf8.count ?? 0) <= 128,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && $0.name.utf8.count <= 1024 &&
                  $0.path.utf8.count <= 32768 && !$0.path.contains("\0") && $0.size >= 0 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return self
    }
}

struct CacheUsage: Codable, Equatable, Sendable {
    var cached: Int64 = 0
    var keptOffline: Int64 = 0
    var free: Int64 = 0
    var measuredAt: Date?
    var onlineOnlyCount: Int64 = 0
    var offlineSelectionCount: Int64 = 0
    var measurementError: String?
    var total: Int64 { NonnegativeTotals.add(cached, keptOffline) }

    func validated() throws -> Self {
        guard cached >= 0, keptOffline >= 0, free >= 0, onlineOnlyCount >= 0, offlineSelectionCount >= 0,
              measuredAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              (measurementError?.utf8.count ?? 0) <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
        return self
    }
}

struct TransferEntry: Codable, Identifiable, Equatable, Sendable {
    enum Direction: String, Codable, Sendable { case uploading, downloading, operation }
    enum State: String, Codable, Sendable { case queued, transferring, completed, failed, interrupted }
    let id: UUID
    var itemID: String
    var name: String
    let direction: Direction
    var state: State
    let started: Date
    var finished: Date?
    var completed: Int64
    var total: Int64
    var bytesPerSecond: Double
    var message: String
    var conflict: Bool = false
    var resolved = false
    var path: String?
    var active: Bool { state == .queued || state == .transferring }
    var fraction: Double? { total > 0 ? min(1, Double(completed) / Double(total)) : nil }

    func validated() throws -> Self {
        guard !itemID.isEmpty, itemID.utf8.count <= 128, name.utf8.count <= 1024, message.utf8.count <= 2048,
              completed >= 0, total >= 0, bytesPerSecond.isFinite, bytesPerSecond >= 0,
              (path?.utf8.count ?? 0) <= 32768, path?.contains("\0") != true,
              started.timeIntervalSinceReferenceDate.isFinite,
              finished?.timeIntervalSinceReferenceDate.isFinite ?? true else { throw CocoaError(.fileReadCorruptFile) }
        return self
    }
}

struct ProviderSnapshot: Codable, Sendable {
    let cache: CacheUsage
    let transfers: [TransferEntry]
    let connection: String
    var rootKeptOffline = false
    var today = DailyTransferTotals()

    func encodedForControl() throws -> Data {
        _ = try validated()
        return try BoundedRecordEncoding.encode(transfers, maximumBytes: 2_097_152, keeping: .last) {
            try JSONEncoder().encode(ProviderSnapshot(cache: cache, transfers: $0, connection: connection,
                rootKeptOffline: rootKeptOffline, today: today))
        }
    }

    func validated() throws -> Self {
        _ = try cache.validated()
        guard transfers.count <= 400, Set(transfers.map(\.id)).count == transfers.count,
              connection.utf8.count <= 128, today.files >= 0, today.uploaded >= 0, today.downloaded >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for entry in transfers { _ = try entry.validated() }
        return self
    }
}
