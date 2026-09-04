import Foundation
import SQLite3
import Logging

/// A thin wrapper over the system SQLite. Deliberately small: the index is the only
/// database in the project and its access patterns are fixed by DESIGN.md section 5.3.
public final class SQLiteConnection {
    public enum OpenMode {
        /// The agent's connection. Creates the file, WAL, one writer.
        case readWrite
        /// The extension's connection (section 5.2). A read-only WAL connection still
        /// has to open the -shm file for writing, because readers publish their read
        /// marks through it; the group container is writable by the sandboxed extension,
        /// which is what makes a read-only reader there possible at all.
        case readOnly
    }

    public struct SQLiteError: Error, LocalizedError {
        public let code: Int32
        public let message: String
        public var errorDescription: String? { "SQLite error \(code): \(message)" }
    }

    let handle: OpaquePointer
    public let path: String

    /// The raw `sqlite3 *`, for the one caller that needs the C API directly: the restore
    /// of section 5.3, which copies a backup *into* this connection with
    /// `sqlite3_backup_init`. Nothing else should reach past the wrapper.
    var rawHandle: OpaquePointer { handle }

    public init(path: String, mode: OpenMode) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags: Int32 = {
            switch mode {
            case .readWrite: return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
            case .readOnly: return SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            }
        }()
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: result, message: message)
        }
        self.handle = opened
        sqlite3_busy_timeout(opened, 5000)
        if case .readWrite = mode {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA foreign_keys=ON")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw SQLiteError(code: result, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let prepared = statement else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(handle: prepared, connection: self)
    }

    /// How deep the nesting is. SQLite has no nested `BEGIN`, and every multi-row change
    /// in section 5.3 wraps itself in a transaction of its own, so the moment section
    /// 5.3's "a directory listing is written in one transaction" rule put a `batch`
    /// around a loop that calls `appendAnchor` and `delete`, the inner `BEGIN IMMEDIATE`
    /// failed with "cannot start a transaction within a transaction" and took the whole
    /// listing with it (2026-09-04).
    private var transactionDepth = 0

    /// Runs `body` inside one transaction, rolling back on any error, and nests.
    ///
    /// The outermost call is the real transaction; an inner one is a `SAVEPOINT`, so an
    /// inner failure that its caller catches undoes only its own writes and an inner
    /// failure that propagates still rolls the whole thing back. Every multi-row change
    /// in section 5.3 is one of these, and several of them legitimately contain others.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let nested = transactionDepth > 0
        let savepoint = "sshdrive_\(transactionDepth)"
        try execute(nested ? "SAVEPOINT \(savepoint)" : "BEGIN IMMEDIATE")
        transactionDepth += 1
        do {
            let value = try body()
            try execute(nested ? "RELEASE \(savepoint)" : "COMMIT")
            transactionDepth -= 1
            return value
        } catch {
            if nested {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            } else {
                try? execute("ROLLBACK")
            }
            transactionDepth -= 1
            throw error
        }
    }

    public var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

/// One prepared statement. Reset and reused; the reader caches its statements and
/// re-prepares them when `meta.generation` moves (section 5.2).
public final class SQLiteStatement {
    private let handle: OpaquePointer
    private unowned let connection: SQLiteConnection

    init(handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    @discardableResult
    public func bind(_ index: Int32, _ value: Int64?) -> SQLiteStatement {
        if let value { sqlite3_bind_int64(handle, index, value) } else { sqlite3_bind_null(handle, index) }
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: Double?) -> SQLiteStatement {
        if let value { sqlite3_bind_double(handle, index, value) } else { sqlite3_bind_null(handle, index) }
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: String?) -> SQLiteStatement {
        if let value {
            sqlite3_bind_text(handle, index, value, -1, SQLiteStatement.transient)
        } else {
            sqlite3_bind_null(handle, index)
        }
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: Data?) -> SQLiteStatement {
        guard let value else {
            sqlite3_bind_null(handle, index)
            return self
        }
        if value.isEmpty {
            // A zero-length blob is not NULL: the root row's path is exactly that.
            sqlite3_bind_zeroblob(handle, index, 0)
        } else {
            value.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(
                    handle, index, buffer.baseAddress, Int32(buffer.count), SQLiteStatement.transient)
            }
        }
        return self
    }

    /// Steps once. Returns true while a row is available.
    public func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw SQLiteConnection.SQLiteError(code: result, message: connection.lastErrorMessage)
        }
    }

    /// Steps to completion, for statements that return no rows.
    public func run() throws {
        while try step() {}
        reset()
    }

    public func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    public func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    public func intOrNil(_ column: Int32) -> Int64? {
        isNull(column) ? nil : sqlite3_column_int64(handle, column)
    }

    public func double(_ column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    public func doubleOrNil(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(handle, column)
    }

    public func string(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: pointer)
    }

    public func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        guard let pointer = sqlite3_column_blob(handle, column) else { return Data() }
        let count = Int(sqlite3_column_bytes(handle, column))
        return Data(bytes: pointer, count: count)
    }
}
