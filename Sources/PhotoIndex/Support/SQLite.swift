//
//  SQLite.swift
//  PhotoIndex
//
//  Created by David Sherlock on 2026.
//
//  The thinnest possible throwing wrapper over the system SQLite. The store
//  is the only caller; this exists so that every C-API call site checks its
//  return code exactly once, here, instead of approximately everywhere.
//

import Foundation
import SQLite3

/// `SQLITE_TRANSIENT`, which the Swift importer loses: tells sqlite to copy
/// bound text and blobs before the statement finalises.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One open SQLite database.
final class Database {

    /// A value crossing into or out of a statement.
    enum Value {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    /// One result row, addressed by column position.
    struct Row {
        let values: [Value]

        func int(_ index: Int) -> Int64? {
            if case .int(let v) = values[index] { return v }
            return nil
        }
        func real(_ index: Int) -> Double? {
            switch values[index] {
            case .real(let v): return v
            case .int(let v): return Double(v)
            default: return nil
            }
        }
        func text(_ index: Int) -> String? {
            if case .text(let v) = values[index] { return v }
            return nil
        }
        func blob(_ index: Int) -> Data? {
            if case .blob(let v) = values[index] { return v }
            return nil
        }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw PhotoIndexError.storage("\(message) (\(path))")
        }
        handle = db
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs statements that take no bindings and return no rows.
    func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw PhotoIndexError.storage("\(message) — in: \(sql.prefix(120))")
        }
    }

    /// Runs one bound statement, discarding any rows.
    func run(_ sql: String, _ binds: [Value] = []) throws {
        _ = try query(sql, binds)
    }

    /// Runs one bound statement and returns its rows.
    func query(_ sql: String, _ binds: [Value] = []) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PhotoIndexError.storage("\(String(cString: sqlite3_errmsg(handle))) — preparing: \(sql.prefix(120))")
        }
        defer { sqlite3_finalize(statement) }

        for (position, value) in binds.enumerated() {
            let slot = Int32(position + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, slot)
            case .int(let v):
                code = sqlite3_bind_int64(statement, slot, v)
            case .real(let v):
                code = sqlite3_bind_double(statement, slot, v)
            case .text(let v):
                code = sqlite3_bind_text(statement, slot, v, -1, transient)
            case .blob(let v):
                code = v.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, slot, bytes.baseAddress, Int32(bytes.count), transient)
                }
            }
            guard code == SQLITE_OK else {
                throw PhotoIndexError.storage("bind \(slot) failed: \(String(cString: sqlite3_errmsg(handle)))")
            }
        }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw PhotoIndexError.storage("\(String(cString: sqlite3_errmsg(handle))) — stepping: \(sql.prefix(120))")
            }
            let count = Int(sqlite3_column_count(statement))
            var values: [Value] = []
            values.reserveCapacity(count)
            for column in 0..<count {
                let c = Int32(column)
                switch sqlite3_column_type(statement, c) {
                case SQLITE_INTEGER:
                    values.append(.int(sqlite3_column_int64(statement, c)))
                case SQLITE_FLOAT:
                    values.append(.real(sqlite3_column_double(statement, c)))
                case SQLITE_TEXT:
                    values.append(.text(String(cString: sqlite3_column_text(statement, c))))
                case SQLITE_BLOB:
                    if let base = sqlite3_column_blob(statement, c) {
                        values.append(.blob(Data(bytes: base, count: Int(sqlite3_column_bytes(statement, c)))))
                    } else {
                        values.append(.blob(Data()))
                    }
                default:
                    values.append(.null)
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// The rowid of the most recent insert.
    var lastInsertID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }
}
