import Foundation
#if canImport(SQLite3)
    import SQLite3
#else
    import CSQLite
#endif
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
        for (_, statement) in statementCache { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    /// Set by a test only, and nil in the shipping agent: called with every statement's
    /// SQL and the transaction depth it was issued at. It is the only way to assert
    /// section 5.3's "a directory listing is written in one transaction", and that the
    /// transaction wraps the **writes** and nothing else, from outside SQLite (`E2` in
    /// `docs/testing-architecture.md`). One optional test per statement, off every path
    /// that matters.
    ///
    /// It fires once per *execution*: every `execute` and every `prepare`, whether the
    /// statement was compiled or taken from the cache below. `compileObserver` is the
    /// other half, and the two together are what say that the cache is working.
    public var statementObserver: (@Sendable (_ sql: String, _ depth: Int) -> Void)?

    /// Set by a test only: called only when `prepare` actually runs
    /// `sqlite3_prepare_v2`, so a test can assert that the number of *compilations* a
    /// listing or an `item(for:)` storm costs is a constant and not a multiple of the
    /// number of rows (section 5.2).
    public var compileObserver: (@Sendable (_ sql: String, _ depth: Int) -> Void)?

    /// Compiled statements, by their SQL text, waiting to be handed out again.
    ///
    /// The index runs a fixed and very small set of statements (section 5.3) over and
    /// over: a 10,000-entry listing is the same three statements ten thousand times, and
    /// an `item(for:)` storm is two. Compiling one per execution is most of what both
    /// cost - 8,006 compilations for a 2,000-entry listing, five per `item(for:)` - so a
    /// statement is reset, cleared and kept instead.
    ///
    /// A statement in this dictionary is idle by construction: `prepare` **removes** it
    /// to hand it out and `SQLiteStatement.deinit` puts it back. So a second `prepare` of
    /// the same SQL while the first is still stepping - one query iterating its rows while
    /// something it calls asks the same question - finds the slot empty and compiles a
    /// statement of its own, which is finalised when it goes rather than displacing the
    /// cached one. Nothing is ever reset or rebound under a caller that is still reading
    /// from it.
    private var statementCache: [String: OpaquePointer] = [:]

    /// Enough for every statement in the module several times over; the bound exists so
    /// that a caller building SQL by interpolation can never grow the cache without end.
    private static let maximumCachedStatements = 64

    /// Takes a statement back after its wrapper has gone. Reset and cleared here rather
    /// than on the way out, so a cached statement never holds a read lock or a stale
    /// binding while it waits.
    fileprivate func checkIn(_ statement: OpaquePointer, sql: String) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        guard statementCache[sql] == nil, statementCache.count < Self.maximumCachedStatements
        else {
            sqlite3_finalize(statement)
            return
        }
        statementCache[sql] = statement
    }

    /// Finalises every cached statement. The one caller is the restore of section 5.3,
    /// which replaces the whole database under this connection: `sqlite3_prepare_v2`
    /// statements re-prepare themselves after a schema change, but an idle statement the
    /// backup API might call "in use" is not worth the argument.
    public func purgeStatementCache() {
        for (_, statement) in statementCache { sqlite3_finalize(statement) }
        statementCache.removeAll(keepingCapacity: true)
    }

    /// The rowid the last successful INSERT on this connection wrote, straight from the C
    /// API rather than through a `SELECT last_insert_rowid()`, which costs a compile and a
    /// step per anchor - 2,000 of each in a 2,000-entry listing (section 5.3).
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    public func execute(_ sql: String) throws {
        statementObserver?(sql, transactionDepth)
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw SQLiteError(code: result, message: message)
        }
    }

    /// A statement ready to bind, from the cache when one is idle and freshly compiled
    /// when none is.
    ///
    /// `sqlite3_prepare_v2` is what makes keeping one safe across a schema change: a
    /// statement it compiled re-prepares itself on the next step rather than answering
    /// `SQLITE_SCHEMA`, so the `ALTER TABLE`s of `IndexWriter.migrate` and the restore of
    /// section 5.3 need no invalidation here.
    public func prepare(_ sql: String) throws -> SQLiteStatement {
        statementObserver?(sql, transactionDepth)
        if let cached = statementCache.removeValue(forKey: sql) {
            return SQLiteStatement(handle: cached, connection: self, sql: sql)
        }
        compileObserver?(sql, transactionDepth)
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let prepared = statement else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(handle: prepared, connection: self, sql: sql)
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

    /// Reports one more *execution* of a statement the caller is reusing.
    ///
    /// `prepare` reports one, which is right when a statement is prepared, bound, stepped
    /// and dropped. A hoisted statement - the listing's row read, its row write and its
    /// anchor, each compiled once and bound ten thousand times (section 5.3) - is prepared
    /// once and executed many times, and `E2` counts executions. So each reuse says so.
    func noteExecution(_ sql: String) { statementObserver?(sql, transactionDepth) }

    public var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Whether a transaction is already open. `IndexWriter.appendAnchor` asks, because a
    /// `SAVEPOINT` around a single `INSERT` that is already inside the listing's one
    /// transaction buys nothing: the statement is atomic by itself, and a throw from
    /// inside `batch` rolls the whole listing back either way (section 5.3).
    public var isInTransaction: Bool { transactionDepth > 0 }
}

/// One prepared statement, on loan from its connection's cache.
///
/// The handle is not finalised when this wrapper goes: it is reset, cleared and put back
/// for the next caller that asks for the same SQL (section 5.2). The connection is held
/// strongly, so a statement can never outlive the database it was compiled against; the
/// cache holds bare handles, so that costs no reference cycle.
public final class SQLiteStatement {
    private let handle: OpaquePointer
    private let connection: SQLiteConnection
    private let sql: String

    init(handle: OpaquePointer, connection: SQLiteConnection, sql: String) {
        self.handle = handle
        self.connection = connection
        self.sql = sql
    }

    deinit {
        connection.checkIn(handle, sql: sql)
    }

    /// Says that this statement is being run again on the same handle, for the statement
    /// observer's benefit. Called by the loops that bind one compiled statement per row.
    public func noteExecution() {
        connection.noteExecution(sql)
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
