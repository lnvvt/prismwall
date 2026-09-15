import Foundation
import SQLite3

/// 轻量 SQLite3 C API 封装（零依赖）。连接全程互斥保护，事务用可重入锁避免嵌套死锁。
enum SQLiteValue {
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

enum LibraryError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "SQLite: \(message)"
        }
    }
}

final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw LibraryError.sqlite(message)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    private func errorMessage() -> LibraryError {
        .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }

    func execute(_ sql: String) throws {
        try lock.withLock {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw errorMessage() }
        }
    }

    func run(_ sql: String, _ bind: [SQLiteValue] = []) throws {
        try lock.withLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw errorMessage()
            }
            defer { sqlite3_finalize(statement) }
            try Self.bind(bind, to: statement!)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw errorMessage() }
        }
    }

    func query<T>(_ sql: String, _ bind: [SQLiteValue] = [], row: (Statement) -> T) throws -> [T] {
        try lock.withLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw errorMessage()
            }
            defer { sqlite3_finalize(statement) }
            try Self.bind(bind, to: statement!)
            var results: [T] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(row(Statement(statement: statement!)))
            }
            return results
        }
    }

    func lastInsertRowID() -> Int64 {
        lock.withLock { sqlite3_last_insert_rowid(db) }
    }

    /// 事务体内可安全调用本类的 run/query（可重入锁）
    func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private static func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        // SQLITE_TRANSIENT：SQLite 在绑定后自行拷贝缓冲区
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number):
                sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                sqlite3_bind_double(statement, index, number)
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, transient)
            case .blob(let data):
                let ok = data.withUnsafeBytes { buffer -> Bool in
                    sqlite3_bind_blob(
                        statement, index, buffer.baseAddress, Int32(data.count), transient
                    ) == SQLITE_OK
                }
                if !ok { throw LibraryError.sqlite("bind blob failed") }
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
    }
}

/// 行读取器（仅在 query 的 row 闭包内有效）
struct Statement {
    let statement: OpaquePointer

    func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func real(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func text(_ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
    func blob(_ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }
    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}
