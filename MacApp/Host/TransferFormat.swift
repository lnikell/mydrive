import Foundation

enum TransferFormat {
    static func speed(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(bytes, Double(Int64.max - 1024))), countStyle: .file) + "/s"
    }

    static func fraction(_ entries: [TransferEntry]) -> Double? {
        let active = entries.filter { $0.active && $0.direction != .operation }
        let total = active.reduce(0.0) { $0 + Double($1.total) }
        guard total > 0 else { return nil }
        return min(1, active.reduce(0.0) { $0 + Double($1.completed) } / total)
    }

    static func summary(_ entries: [TransferEntry]) -> String {
        let active = entries.filter { $0.active && $0.direction != .operation }
        let total = active.reduce(Int64(0)) { NonnegativeTotals.add($0, $1.total) }
        let completed = active.reduce(Int64(0)) { NonnegativeTotals.add($0, $1.completed) }
        let speed = active.reduce(0.0) { $0 + $1.bytesPerSecond }
        guard !active.isEmpty else { return "Preparing changes…" }
        var text = "\(active.count) \(active.count == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        if speed > 0 {
            text += " · " + self.speed(speed)
            let seconds = Double(max(0, total - completed)) / speed
            if seconds.isFinite { text += " · \(Int(min(ceil(seconds), 86400))) s left" }
        }
        return text
    }
}
