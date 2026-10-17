import CSQLite
import Foundation

enum SQLValue {
    case text(String), integer(Int64), real(Double), null

    init(_ value: String?) { self = value.map(Self.text) ?? .null }
    init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

/// Access is confined to Catalog's actor. FULLMUTEX also protects SQLite during
/// connection cleanup; no SQLite pointer escapes this implementation.
final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(url: URL, cacheKiB: Int) throws {
        guard url.isFileURL, !url.path.contains("\0"), cacheKiB > 0 else { throw CatalogError.localDatabaseRequired }
        let resolvedURL = url.resolvingSymlinksInPath()
        let directory = resolvedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try directory.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
            throw CatalogError.localDatabaseRequired
        }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            resolvedURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open SQLite"
            if let opened { sqlite3_close_v2(opened) }
            throw CatalogError.sqlite(code: result, message: message)
        }
        handle = opened
        do {
            sqlite3_busy_timeout(handle, 2_000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA fullfsync = ON")
            try execute("PRAGMA cache_size = -\(cacheKiB)")
            try execute("PRAGMA mmap_size = 0")
            try execute("PRAGMA wal_autocheckpoint = 256")
            let mode = try scalarText("PRAGMA journal_mode")
            let sync = try scalarInt("PRAGMA synchronous")
            guard mode == "wal", sync == 2 else {
                throw CatalogError.sqlite(code: SQLITE_MISUSE, message: "Durability settings were not applied")
            }
        } catch {
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        try statement(sql, values) { statement in
            while try statement.step() { }
        }
    }

    func script(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw failure(result) }
    }

    func statement<T>(
        _ sql: String, _ values: [SQLValue] = [], _ body: (SQLStatement) throws -> T
    ) throws -> T {
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else { throw failure(result) }
        defer { sqlite3_finalize(prepared) }
        guard let handle else { throw CatalogError.sqlite(code: SQLITE_MISUSE, message: "Closed SQLite connection") }
        let statement = SQLStatement(handle: prepared, connection: handle)
        try statement.bind(values)
        return try body(statement)
    }

    func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
        try statement(sql, values) {
            guard try $0.step() else { throw CatalogError.sqlite(code: SQLITE_NOTFOUND, message: "Missing scalar") }
            return $0.integer(0)
        }
    }

    func scalarText(_ sql: String, _ values: [SQLValue] = []) throws -> String {
        try statement(sql, values) {
            guard try $0.step() else { throw CatalogError.sqlite(code: SQLITE_NOTFOUND, message: "Missing scalar") }
            return $0.text(0)
        }
    }

    func transaction<T>(write: Bool = true, _ body: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func failure(_ code: Int32) -> CatalogError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}

struct SQLStatement {
    let handle: OpaquePointer
    let connection: OpaquePointer

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string):
                guard let count = Int32(exactly: string.utf8.count) else { throw failure(SQLITE_TOOBIG) }
                result = string.withCString {
                    sqlite3_bind_text(handle, index, $0, count, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .integer(let integer): result = sqlite3_bind_int64(handle, index, integer)
            case .real(let double): result = sqlite3_bind_double(handle, index, double)
            case .null: result = sqlite3_bind_null(handle, index)
            }
            guard result == SQLITE_OK else { throw failure(result) }
        }
    }

    func reset() throws {
        let result = sqlite3_reset(handle)
        guard result == SQLITE_OK else { throw failure(result) }
        let cleared = sqlite3_clear_bindings(handle)
        guard cleared == SQLITE_OK else { throw failure(cleared) }
    }

    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        case let code: throw failure(code)
        }
    }

    func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func real(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String {
        guard let value = sqlite3_column_text(handle, column) else { return "" }
        let count = Int(sqlite3_column_bytes(handle, column))
        return String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF8.self)
    }
    func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }

    private func failure(_ code: Int32) -> CatalogError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(connection)))
    }
}
