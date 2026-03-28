import Foundation
import SQLite3

/// Defines and creates the SQLite schema for the Learning module.
/// All tables use IF NOT EXISTS for safe re-initialization.
enum LearningSchema {

    /// Creates all tables and indices. Called once during LearningDatabase initialization.
    static func createTables(db: OpaquePointer?, queue: DispatchQueue) {
        let sql = """
        -- Raw user action observations
        CREATE TABLE IF NOT EXISTS observations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            app_name TEXT NOT NULL,
            app_bundle_id TEXT,
            element_role TEXT,
            element_title TEXT,
            element_value TEXT,
            window_title TEXT,
            timestamp REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_obs_app_time ON observations(app_name, timestamp);
        CREATE INDEX IF NOT EXISTS idx_obs_time ON observations(timestamp);

        -- Extracted workflow patterns
        CREATE TABLE IF NOT EXISTS patterns (
            id TEXT PRIMARY KEY,
            app_name TEXT NOT NULL,
            name TEXT NOT NULL,
            actions_json TEXT NOT NULL,
            frequency INTEGER DEFAULT 1,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_pat_app_freq ON patterns(app_name, frequency DESC);

        -- Schema version tracking for future migrations
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY
        );
        INSERT OR IGNORE INTO schema_version (version) VALUES (1);
        """

        queue.sync {
            var errmsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "unknown"
                print("[LearningDB] Schema error: \(msg)")
                sqlite3_free(errmsg)
            } else {
                print("[LearningDB] Schema initialized (v1)")
            }
        }
    }

    /// Returns the current schema version.
    static func currentVersion(db: OpaquePointer?, queue: DispatchQueue) -> Int {
        queue.sync {
            let sql = "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }
}
