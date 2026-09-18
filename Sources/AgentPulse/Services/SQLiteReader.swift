import Foundation
import SQLite3

/// Minimal read-only access to VS Code style `state.vscdb` key/value stores.
enum SQLiteReader {
    struct Failure: Error { var message: String }

    static func values(forKeys keys: [String], dbPath: URL) throws -> [String: String] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var rc = sqlite3_open_v2(dbPath.path, &db, flags, nil)
        if rc != SQLITE_OK {
            // A WAL-mode store whose -shm sidecar is missing can't be opened read-only; a
            // locking-free immutable open still lets us read the (stable) auth keys.
            sqlite3_close(db)
            db = nil
            let uri = "file:\(dbPath.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath.path)?immutable=1"
            rc = sqlite3_open_v2(uri, &db, flags | SQLITE_OPEN_URI, nil)
        }
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database."
            sqlite3_close(db)
            throw Failure(message: message)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result: [String: String] = [:]
        for key in keys {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            if sqlite3_step(statement) == SQLITE_ROW {
                if let bytes = sqlite3_column_text(statement, 0) {
                    result[key] = String(cString: bytes)
                } else if let blob = sqlite3_column_blob(statement, 0) {
                    let count = Int(sqlite3_column_bytes(statement, 0))
                    result[key] = String(decoding: Data(bytes: blob, count: count), as: UTF8.self)
                }
            }
        }
        return result
    }
}
