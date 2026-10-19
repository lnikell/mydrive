import Foundation

/// The coordinator owns this ledger. It observes callback Progress without
/// changing File Provider's scheduling, completion, or materialization flags.
final class TransferLedger {
    private struct Running {
        let progress: Progress
        var expectedBytes: Int64?
        var lastBytes: Int64
        var lastSample: Date
    }
    private var records: [TransferEntry] = []
    private var running: [UUID: Running] = [:]
    private let url: URL

    init(url: URL) {
        self.url = url
        if let bytes = try? BoundedFile.read(url, maximumBytes: 1_048_576),
           let saved = try? JSONDecoder().decode([TransferEntry].self, from: bytes) {
            records = Array(saved.filter { (try? $0.validated()) != nil }.suffix(200))
            for index in records.indices where records[index].active {
                records[index].state = .interrupted
                records[index].message = "Interrupted. Finder retains pending work and retries it."
                records[index].finished = Date()
            }
        }
    }

    func begin(itemID: String, name: String, direction: TransferEntry.Direction, progress: Progress, expectedBytes: Int64? = nil, path: String? = nil) -> UUID {
        let id = UUID(), now = Date()
        records.append(TransferEntry(id: id, itemID: itemID, name: name, direction: direction,
            state: .queued, started: now, completed: 0, total: max(0, expectedBytes ?? progress.totalUnitCount), bytesPerSecond: 0, message: "Waiting for transfer", path: path))
        running[id] = Running(progress: progress, expectedBytes: expectedBytes, lastBytes: 0, lastSample: now)
        EventLog.record("transfer_started", verbose: true)
        trimAndSave()
        return id
    }

    func finish(_ id: UUID, error: (any Error)? = nil, name: String? = nil, itemID: String? = nil, conflict: Bool = false, bytes: Int64? = nil) {
        sample()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        running.removeValue(forKey: id)
        records[index].state = error == nil ? .completed : (error is CancellationError ? .interrupted : .failed)
        records[index].finished = Date()
        records[index].bytesPerSecond = 0
        if error == nil, let bytes, bytes >= 0, records[index].direction != .operation {
            records[index].completed = bytes; records[index].total = bytes
        }
        records[index].conflict = conflict
        if let name { records[index].name = name }
        if let itemID { records[index].itemID = itemID }
        if error == nil {
            let resolvedItem = records[index].itemID
            for old in records.indices where old != index && records[old].itemID == resolvedItem && !records[old].active {
                records[old].resolved = true
            }
        }
        records[index].message = String((error?.localizedDescription ?? (conflict ? "Conflict resolved by keeping both copies." : "Finished")).prefix(512))
        EventLog.record(error == nil ? "transfer_completed" : "transfer_failed", error: error, verbose: error == nil)
        trimAndSave()
    }

    /// Preparation binds a create template to its durable identity before any
    /// upload starts. Keep the same activity so journal projections and retries
    /// refer to one item, including when the eventual remote operation fails.
    func prepared(_ id: UUID, itemID: String, path: String?, bytes: Int64?) {
        guard let index = records.firstIndex(where: { $0.id == id }), var task = running[id] else { return }
        records[index].itemID = itemID
        if let path { records[index].path = path }
        if let bytes {
            task.expectedBytes = max(0, bytes)
            records[index].total = max(0, bytes)
        }
        running[id] = task
        trimAndSave()
    }

    func snapshot() -> [TransferEntry] { sample(); return Array(records.suffix(400)) }

    func clearCompleted() { records.removeAll { !$0.active }; trimAndSave() }

    func resolve(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id && !$0.active }) else { return }
        records[index].resolved = true
        trimAndSave()
    }

    private func sample() {
        let now = Date()
        for index in records.indices {
            let id = records[index].id
            guard var task = running[id] else { continue }
            let total = max(0, task.expectedBytes ?? task.progress.totalUnitCount)
            let bytes = min(total, max(0, task.progress.completedUnitCount))
            let elapsed = now.timeIntervalSince(task.lastSample)
            records[index].completed = bytes
            records[index].total = total
            if bytes > 0 { records[index].state = .transferring }
            records[index].message = bytes > 0 ? "Transferring" : "Preparing"
            if elapsed >= 0.25 {
                records[index].bytesPerSecond = records[index].direction == .operation ? 0 : max(0, Double(bytes - task.lastBytes) / elapsed)
                task.lastBytes = bytes; task.lastSample = now
                running[id] = task
            }
        }
    }

    private func trimAndSave() {
        // Keep active callbacks, plus a bounded recent history across restarts.
        let completed = records.filter { !$0.active }.suffix(200)
        records = (Array(completed) + records.filter(\.active)).sorted { $0.started < $1.started }
        guard let data = try? BoundedRecordEncoding.encode(Array(records.suffix(400)), maximumBytes: 1_048_576,
            keeping: .last, envelope: { try JSONEncoder().encode($0) }) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
