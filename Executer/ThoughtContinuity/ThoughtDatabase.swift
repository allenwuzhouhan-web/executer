import Foundation
import SQLite3

struct ThoughtRow {
    let id: Int64
    let appBundleId: String
    let appName: String
    let windowTitle: String?
    let textContent: String
    let timestamp: Date
    let isComplete: Bool
    let metadataJSON: String?
    let agentNamespace: String
}

final class ThoughtDatabase {
    static let shared = ThoughtDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.executer.thoughtdb", qos: .utility)

    private init() {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("thoughts.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[ThoughtDB] Failed to open, recreating")
            try? FileManager.default.removeItem(atPath: dbPath)
            if sqlite3_open(dbPath, &db) != SQLITE_OK {
                print("[ThoughtDB] Fatal: cannot create database")
                return
            }
        }

        createSchema()
        migrateSchema()
        pruneOlderThan(days: 7)
    }

    private func createSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS thoughts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_bundle_id TEXT NOT NULL,
            app_name TEXT NOT NULL,
            window_title TEXT,
            text_content TEXT NOT NULL,
            timestamp REAL NOT NULL,
            is_complete INTEGER DEFAULT 0,
            metadata_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_thoughts_timestamp ON thoughts(timestamp);
        CREATE INDEX IF NOT EXISTS idx_thoughts_app ON thoughts(app_bundle_id);
        """
        queue.sync {
            var errmsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "unknown"
                print("[ThoughtDB] Schema error: \(msg)")
                sqlite3_free(errmsg)
            }
        }
    }

    // MARK: - Insert

    @discardableResult
    func insert(appBundleId: String, appName: String, windowTitle: String?, textContent: String, metadataJSON: String? = nil) -> Int64 {
        queue.sync {
            let sql = "INSERT INTO thoughts (app_bundle_id, app_name, window_title, text_content, timestamp, metadata_json) VALUES (?, ?, ?, ?, ?, ?)"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }

            sqlite3_bind_text(stmt, 1, (appBundleId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (appName as NSString).utf8String, -1, nil)
            if let title = windowTitle {
                sqlite3_bind_text(stmt, 3, (title as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, (textContent as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
            if let meta = metadataJSON {
                sqlite3_bind_text(stmt, 6, (meta as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[ThoughtDB] Insert failed")
                return -1
            }

            return sqlite3_last_insert_rowid(db)
        }
    }

    // MARK: - Query

    func mostRecentForApp(bundleId: String) -> ThoughtRow? {
        queue.sync {
            let sql = "SELECT * FROM thoughts WHERE app_bundle_id = ? ORDER BY timestamp DESC LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, (bundleId as NSString).utf8String, -1, nil)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return rowFromStatement(stmt)
        }
    }

    /// Find thoughts where the user left the app more than `abandonedAfter` seconds ago
    /// and has not returned to that app since.
    func abandonedThoughts(abandonedAfter: TimeInterval = 300) -> [ThoughtRow] {
        queue.sync {
            let cutoff = Date().timeIntervalSince1970 - abandonedAfter
            // Get the most recent thought per app that's older than cutoff and not complete
            let sql = """
            SELECT t.* FROM thoughts t
            INNER JOIN (
                SELECT app_bundle_id, MAX(timestamp) as max_ts
                FROM thoughts
                WHERE is_complete = 0
                GROUP BY app_bundle_id
            ) latest ON t.app_bundle_id = latest.app_bundle_id AND t.timestamp = latest.max_ts
            WHERE t.timestamp < ? AND t.is_complete = 0
            ORDER BY t.timestamp DESC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_double(stmt, 1, cutoff)

            var results: [ThoughtRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(rowFromStatement(stmt)!)
            }
            return results
        }
    }

    /// Check if the user has returned to this app since the given timestamp.
    func hasNewerThought(bundleId: String, since timestamp: Date) -> Bool {
        queue.sync {
            let sql = "SELECT COUNT(*) FROM thoughts WHERE app_bundle_id = ? AND timestamp > ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            sqlite3_bind_text(stmt, 1, (bundleId as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, timestamp.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int(stmt, 0) > 0
        }
    }

    // MARK: - Update

    func markComplete(id: Int64) {
        queue.sync {
            let sql = "UPDATE thoughts SET is_complete = 1 WHERE id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Search & Recent

    struct ThoughtRecord {
        let appName: String
        let windowTitle: String?
        let textContent: String
        let timestamp: Date
    }

    func recentThoughts(limit: Int = 10) -> [ThoughtRecord] {
        queue.sync {
            let sql = "SELECT app_name, window_title, text_content, timestamp FROM thoughts ORDER BY timestamp DESC LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var results: [ThoughtRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let appName = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let windowTitle = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                results.append(ThoughtRecord(appName: appName, windowTitle: windowTitle, textContent: text, timestamp: ts))
            }
            return results
        }
    }

    func searchThoughts(query: String, limit: Int = 10) -> [ThoughtRecord] {
        queue.sync {
            // Use LIKE for simple text search (FTS5 would be better but requires schema migration)
            let sql = "SELECT app_name, window_title, text_content, timestamp FROM thoughts WHERE text_content LIKE ? OR window_title LIKE ? ORDER BY timestamp DESC LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            let pattern = "%\(query)%"
            sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(limit))

            var results: [ThoughtRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let appName = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let windowTitle = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                results.append(ThoughtRecord(appName: appName, windowTitle: windowTitle, textContent: text, timestamp: ts))
            }
            return results
        }
    }

    // MARK: - Prune

    func pruneOlderThan(days: Int) {
        queue.sync {
            let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
            let sql = "DELETE FROM thoughts WHERE timestamp < ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, cutoff)

            if sqlite3_step(stmt) == SQLITE_DONE {
                let deleted = sqlite3_changes(db)
                if deleted > 0 {
                    print("[ThoughtDB] Pruned \(deleted) old entries")
                }
            }
        }
    }

    // MARK: - Helpers

    private func rowFromStatement(_ stmt: OpaquePointer?) -> ThoughtRow? {
        guard let stmt = stmt else { return nil }

        let id = sqlite3_column_int64(stmt, 0)
        let bundleId = String(cString: sqlite3_column_text(stmt, 1))
        let appName = String(cString: sqlite3_column_text(stmt, 2))
        let windowTitle: String? = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let textContent = String(cString: sqlite3_column_text(stmt, 4))
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let isComplete = sqlite3_column_int(stmt, 6) != 0
        let metadataJSON: String? = sqlite3_column_text(stmt, 7).map { String(cString: $0) }

        let agentNamespace: String
        if sqlite3_column_count(stmt) > 8, let ns = sqlite3_column_text(stmt, 8) {
            agentNamespace = String(cString: ns)
        } else {
            agentNamespace = "general"
        }

        return ThoughtRow(
            id: id,
            appBundleId: bundleId,
            appName: appName,
            windowTitle: windowTitle,
            textContent: textContent,
            timestamp: timestamp,
            isComplete: isComplete,
            metadataJSON: metadataJSON,
            agentNamespace: agentNamespace
        )
    }

    /// Add agent_namespace column if it doesn't exist yet.
    private func migrateSchema() {
        queue.sync {
            // Check if column exists by querying pragma
            let sql = "PRAGMA table_info(thoughts)"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            var hasNamespace = false
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let name = sqlite3_column_text(stmt, 1) {
                        if String(cString: name) == "agent_namespace" {
                            hasNamespace = true
                            break
                        }
                    }
                }
            }

            if !hasNamespace {
                var errmsg: UnsafeMutablePointer<CChar>?
                let alter = "ALTER TABLE thoughts ADD COLUMN agent_namespace TEXT DEFAULT 'general'"
                if sqlite3_exec(db, alter, nil, nil, &errmsg) != SQLITE_OK {
                    let msg = errmsg.map { String(cString: $0) } ?? "unknown"
                    print("[ThoughtDB] Migration error: \(msg)")
                    sqlite3_free(errmsg)
                } else {
                    print("[ThoughtDB] Added agent_namespace column")
                }
            }
            // Create namespace index (after column is guaranteed to exist)
            var idxErr: UnsafeMutablePointer<CChar>?
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_thoughts_namespace ON thoughts(agent_namespace)", nil, nil, &idxErr)
            sqlite3_free(idxErr)
        }
    }

    deinit {
        sqlite3_close(db)
    }
}
