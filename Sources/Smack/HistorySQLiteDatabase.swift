import Foundation
import SQLite3

struct HistorySQLiteDatabase: @unchecked Sendable {
    let handle: OpaquePointer

    static func open(at url: URL) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open history database"
            sqlite3_close_v2(connection)
            throw HistoryRepositoryError.sqlite(code: result, message: message)
        }
        sqlite3_busy_timeout(connection, 5_000)
        return connection
    }

    func close() {
        sqlite3_close_v2(handle)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw sqliteError(code: result) }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw sqliteError(code: result) }
        return statement
    }

    static func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    static func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_double(statement, index, value)
    }

    static func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, value)
    }

    static func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError(code: result) }
    }

    static func stringColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    func integerQuery(_ sql: String) throws -> Int {
        try withStatement(sql) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw sqliteError(code: result) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func databaseSize() throws -> Int {
        try integerQuery("PRAGMA page_count") * integerQuery("PRAGMA page_size")
    }

    func usedStorageBytes() throws -> Int {
        try (integerQuery("PRAGMA page_count") - integerQuery("PRAGMA freelist_count")) * integerQuery("PRAGMA page_size")
    }

    func compactFile() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
    }

    func sqliteError(code: Int32) -> HistoryRepositoryError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}
