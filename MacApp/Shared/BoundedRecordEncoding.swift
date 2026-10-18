import Foundation

/// Keep whole observations within the reader's byte bound, including JSON
/// escaping and envelope overhead. This never changes the underlying work.
enum BoundedRecordEncoding {
    enum End { case first, last }

    static func encode<Record>(_ records: [Record], maximumBytes: Int, keeping end: End,
                               envelope: ([Record]) throws -> Data) throws -> Data {
        let full = try envelope(records)
        if full.count <= maximumBytes { return full }
        var best = try envelope([])
        guard best.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        var low = 0, high = records.count
        while low < high {
            let count = low + (high - low + 1) / 2
            let selected = end == .first ? Array(records.prefix(count)) : Array(records.suffix(count))
            let data = try envelope(selected)
            if data.count <= maximumBytes { low = count; best = data }
            else { high = count - 1 }
        }
        return best
    }
}
