import CSQLite
import Darwin
import Foundation
import MyDriveCore

/// SQLite bounds both the discovery frontier and replay pages independently
/// of tree width. It contains input metadata only; Core owns execution state.
final class LocalTreeIndex {
    struct Node { let path: String; let kind: ItemKind; let source: LocalTreeSource }
    private let database: OpaquePointer

    init(directory: URL, create: Bool) throws {
        let path = directory.appendingPathComponent("manifest.sqlite").path
        if !create {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadCorruptFile) }
        }
        var opened: OpaquePointer?
        let flags = create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &opened, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw CocoaError(.fileReadCorruptFile)
        }
        database = opened
        do {
            try execute("PRAGMA trusted_schema=OFF")
            if create {
                try execute("PRAGMA journal_mode=DELETE")
                try execute("PRAGMA synchronous=FULL")
                try execute("CREATE TABLE nodes(path TEXT PRIMARY KEY COLLATE BINARY,kind TEXT NOT NULL,source BLOB NOT NULL,payload BLOB,walked INTEGER NOT NULL) WITHOUT ROWID")
                try execute("CREATE INDEX pending_directories ON nodes(walked,kind,path)")
                try execute("CREATE TABLE metadata(value BLOB NOT NULL)")
                try execute("BEGIN IMMEDIATE")
            }
        } catch { sqlite3_close(database); throw error }
    }

    deinit { sqlite3_close(database) }

    func insert(path: String, kind: ItemKind, source: LocalTreeSource, payload: StagedPayload?) throws {
        try execute("INSERT INTO nodes VALUES(?,?,?,?,?)", [.text(path),.text(kind.rawValue),
            .data(try JSONEncoder().encode(source)), try payload.map { .data(try JSONEncoder().encode($0)) } ?? .null,
            .number(kind == .directory ? 0 : 1)])
    }

    func nextDirectory() throws -> Node? {
        try query("SELECT path,kind,source FROM nodes WHERE walked=0 AND kind='directory' ORDER BY path COLLATE BINARY LIMIT 1").first.map(node)
    }
    func node(_ path: String) throws -> Node? {
        try query("SELECT path,kind,source FROM nodes WHERE path=?", [.text(path)]).first.map(node)
    }
    func seal(_ path: String) throws { try execute("UPDATE nodes SET walked=1 WHERE path=?", [.text(path)]) }

    func entries(after: String?, limit: Int) throws -> [TreeImportEntry] {
        guard (1...1000).contains(limit) else { throw CocoaError(.fileReadCorruptFile) }
        let rows = try query("SELECT path,kind,payload FROM nodes \(after == nil ? "" : "WHERE path>?") ORDER BY path COLLATE BINARY LIMIT ?",
            (after.map { [.text($0)] } ?? []) + [.number(Int64(limit))])
        return try rows.map {
            guard let kind = ItemKind(rawValue: try $0[1].text()) else { throw CocoaError(.fileReadCorruptFile) }
            let payload = $0[2] == .null ? nil : try JSONDecoder().decode(StagedPayload.self, from: $0[2].data())
            return TreeImportEntry(path: try $0[0].text(), kind: kind, payload: payload)
        }
    }

    func directories(after: String?, limit: Int, descending: Bool = false) throws -> [Node] {
        guard (1...1000).contains(limit) else { throw CocoaError(.fileReadCorruptFile) }
        let comparison = descending ? "<" : ">", direction = descending ? "DESC" : "ASC"
        return try query("SELECT path,kind,source FROM nodes WHERE kind='directory' \(after == nil ? "" : "AND path\(comparison)?") ORDER BY path COLLATE BINARY \(direction) LIMIT ?",
            (after.map { [.text($0)] } ?? []) + [.number(Int64(limit))]).map(node)
    }

    func sources(after: String?, limit: Int) throws -> [Node] {
        guard (1...1000).contains(limit) else { throw CocoaError(.fileReadCorruptFile) }
        return try query("SELECT path,kind,source FROM nodes \(after == nil ? "" : "WHERE path>?") ORDER BY path COLLATE BINARY LIMIT ?",
            (after.map { [.text($0)] } ?? []) + [.number(Int64(limit))]).map(node)
    }

    func finish(_ reference: StagedTreeReference) throws {
        let data = try JSONEncoder().encode(reference)
        try execute("INSERT INTO metadata VALUES(?)", [.data(data)])
        try execute("COMMIT")
    }
    func reference() throws -> StagedTreeReference {
        let rows = try query("SELECT value FROM metadata LIMIT 2")
        guard rows.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try rows[0][0].data()
        guard data.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(StagedTreeReference.self, from: data)
    }

    private func node(_ row: [Value]) throws -> Node {
        guard let kind = ItemKind(rawValue: try row[1].text()) else { throw CocoaError(.fileReadCorruptFile) }
        let source = try JSONDecoder().decode(LocalTreeSource.self, from: row[2].data())
        return Node(path: try row[0].text(), kind: kind, source: source)
    }

    private enum Value: Equatable {
        case text(String), data(Data), number(Int64), null
        func text() throws -> String { guard case .text(let value) = self else { throw CocoaError(.fileReadCorruptFile) }; return value }
        func data() throws -> Data { guard case .data(let value) = self else { throw CocoaError(.fileReadCorruptFile) }; return value }
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws { _ = try query(sql, values) }
    private func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .text(let text):
                result = text.utf8CString.withUnsafeBufferPointer { sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), transient) }
            case .data(let data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .number(let number): result = sqlite3_bind_int64(statement, index, number)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
        var rows: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw CocoaError(.fileWriteUnknown) }
            var row: [Value] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL: row.append(.null)
                case SQLITE_INTEGER: row.append(.number(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT:
                    let size = Int(sqlite3_column_bytes(statement, column))
                    guard size <= 4096, let text = sqlite3_column_text(statement, column),
                          let value = String(bytes: UnsafeBufferPointer(start: text, count: size), encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                    row.append(.text(value))
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(statement, column))
                    guard size <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
                    if size == 0 { row.append(.data(Data())) }
                    else {
                        guard let data = sqlite3_column_blob(statement, column) else { throw CocoaError(.fileReadCorruptFile) }
                        row.append(.data(Data(bytes: data, count: size)))
                    }
                default: throw CocoaError(.fileReadCorruptFile)
                }
            }
            rows.append(row)
        }
    }
}
