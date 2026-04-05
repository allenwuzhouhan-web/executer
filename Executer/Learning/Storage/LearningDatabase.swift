import Foundation
import SQLite3

final class LearningDatabase {
    static let shared = LearningDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.executer.learningdb", qos: .utility)

    private init() {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent(LearningConstants.appSupportSubdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent(LearningConstants.databaseFilename).path

        decryptForUse(at: dbPath)
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[LearningDB] Failed to open, recreating")
            try? FileManager.default.removeItem(atPath: dbPath)
            if sqlite3_open(dbPath, &db) != SQLITE_OK {
                print("[LearningDB] Fatal: cannot create database")
                return
            }
        }

        configurePragmas()
        LearningSchema.createTables(db: db, queue: queue)
    }

    private func configurePragmas() {
        queue.sync {
            // WAL mode for concurrent reads during writes (M-series optimization)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            // Incremental vacuum to reclaim space after pruning
            sqlite3_exec(db, "PRAGMA auto_vacuum=INCREMENTAL", nil, nil, nil)
            // Synchronous NORMAL for better write performance (safe with WAL)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            // M-series optimizations: mmap for zero-copy reads, large page cache, temp in RAM
            sqlite3_exec(db, "PRAGMA mmap_size=268435456", nil, nil, nil)      // 256MB
            sqlite3_exec(db, "PRAGMA cache_size=-64000", nil, nil, nil)         // 64MB
            sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        }
    }

    // MARK: - Observations

    func insertObservation(_ action: UserAction) {
        queue.sync {
            let sql = """
            INSERT INTO observations (type, app_name, app_bundle_id, element_role, element_title, element_value, window_title, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            sqlite3_bind_text(stmt, 1, (action.type.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (action.appName as NSString).utf8String, -1, nil)
            sqlite3_bind_null(stmt, 3) // bundle_id populated later by Attention layer
            sqlite3_bind_text(stmt, 4, (action.elementRole as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (action.elementTitle as NSString).utf8String, -1, nil)
            let sanitizedValue = ContentFilter.sanitize(action.elementValue)
            sqlite3_bind_text(stmt, 6, (sanitizedValue as NSString).utf8String, -1, nil)
            sqlite3_bind_null(stmt, 7) // window_title populated later
            sqlite3_bind_double(stmt, 8, action.timestamp.timeIntervalSince1970)

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[LearningDB] Insert observation failed")
            }
        }
    }

    func insertObservations(_ actions: [UserAction]) {
        queue.sync {
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

            let sql = """
            INSERT INTO observations (type, app_name, app_bundle_id, element_role, element_title, element_value, window_title, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }

            var transactionFailed = false
            for action in actions {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, (action.type.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (action.appName as NSString).utf8String, -1, nil)
                sqlite3_bind_null(stmt, 3)
                sqlite3_bind_text(stmt, 4, (action.elementRole as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (action.elementTitle as NSString).utf8String, -1, nil)
                let sanitizedValue = ContentFilter.sanitize(action.elementValue)
                sqlite3_bind_text(stmt, 6, (sanitizedValue as NSString).utf8String, -1, nil)
                sqlite3_bind_null(stmt, 7)
                sqlite3_bind_double(stmt, 8, action.timestamp.timeIntervalSince1970)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    let errMsg = String(cString: sqlite3_errmsg(db))
                    print("[LearningDB] Batch insert observation failed: \(errMsg)")
                    transactionFailed = true
                    break
                }
            }

            sqlite3_finalize(stmt)
            if transactionFailed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            } else {
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
            }
        }
    }

    func recentObservations(forApp appName: String, limit: Int = 500) -> [UserAction] {
        queue.sync {
            let sql = "SELECT type, app_name, element_role, element_title, element_value, timestamp FROM observations WHERE app_name = ? ORDER BY timestamp DESC LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            sqlite3_bind_text(stmt, 1, (appName as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var results: [UserAction] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let type = UserAction.ActionType(rawValue: String(cString: sqlite3_column_text(stmt, 0))) ?? .focus
                let app = String(cString: sqlite3_column_text(stmt, 1))
                let role = String(cString: sqlite3_column_text(stmt, 2))
                let title = String(cString: sqlite3_column_text(stmt, 3))
                let value = String(cString: sqlite3_column_text(stmt, 4))
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                results.append(UserAction(type: type, appName: app, elementRole: role, elementTitle: title, elementValue: value, timestamp: ts))
            }
            return results.reversed() // chronological order
        }
    }

    // MARK: - Patterns

    func insertOrUpdatePattern(_ pattern: WorkflowPattern) {
        queue.sync {
            // Check if exists
            let checkSQL = "SELECT frequency FROM patterns WHERE id = ?"
            var checkStmt: OpaquePointer?
            defer { sqlite3_finalize(checkStmt) }
            guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(checkStmt, 1, (pattern.id.uuidString as NSString).utf8String, -1, nil)

            if sqlite3_step(checkStmt) == SQLITE_ROW {
                // Update frequency
                let updateSQL = "UPDATE patterns SET frequency = ?, last_seen = ? WHERE id = ?"
                var updateStmt: OpaquePointer?
                defer { sqlite3_finalize(updateStmt) }
                guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else { return }
                sqlite3_bind_int(updateStmt, 1, Int32(pattern.frequency))
                sqlite3_bind_double(updateStmt, 2, pattern.lastSeen.timeIntervalSince1970)
                sqlite3_bind_text(updateStmt, 3, (pattern.id.uuidString as NSString).utf8String, -1, nil)
                sqlite3_step(updateStmt)
            } else {
                // Insert new
                let insertSQL = "INSERT INTO patterns (id, app_name, name, actions_json, frequency, first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?)"
                var insertStmt: OpaquePointer?
                defer { sqlite3_finalize(insertStmt) }
                guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else { return }

                let actionsData = (try? JSONEncoder().encode(pattern.actions)) ?? Data()
                let actionsJSON = String(data: actionsData, encoding: .utf8) ?? "[]"

                sqlite3_bind_text(insertStmt, 1, (pattern.id.uuidString as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 2, (pattern.appName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 3, (pattern.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 4, (actionsJSON as NSString).utf8String, -1, nil)
                sqlite3_bind_int(insertStmt, 5, Int32(pattern.frequency))
                sqlite3_bind_double(insertStmt, 6, pattern.firstSeen.timeIntervalSince1970)
                sqlite3_bind_double(insertStmt, 7, pattern.lastSeen.timeIntervalSince1970)
                sqlite3_step(insertStmt)
            }
        }
    }

    func topPatterns(forApp appName: String, limit: Int = 20) -> [WorkflowPattern] {
        queue.sync {
            let sql = "SELECT id, app_name, name, actions_json, frequency, first_seen, last_seen FROM patterns WHERE app_name = ? ORDER BY frequency DESC LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            sqlite3_bind_text(stmt, 1, (appName as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var results: [WorkflowPattern] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID()
                let app = String(cString: sqlite3_column_text(stmt, 1))
                let name = String(cString: sqlite3_column_text(stmt, 2))
                let actionsJSON = String(cString: sqlite3_column_text(stmt, 3))
                let frequency = Int(sqlite3_column_int(stmt, 4))
                let firstSeen = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                let lastSeen = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))

                let actions: [WorkflowPattern.PatternAction]
                if let data = actionsJSON.data(using: .utf8) {
                    actions = (try? JSONDecoder().decode([WorkflowPattern.PatternAction].self, from: data)) ?? []
                } else {
                    actions = []
                }

                results.append(WorkflowPattern(id: id, appName: app, name: name, actions: actions, frequency: frequency, firstSeen: firstSeen, lastSeen: lastSeen))
            }
            return results
        }
    }

    func replacePatterns(forApp appName: String, patterns: [WorkflowPattern]) {
        queue.sync {
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

            // Delete existing patterns for this app
            let delSQL = "DELETE FROM patterns WHERE app_name = ?"
            var delStmt: OpaquePointer?
            sqlite3_prepare_v2(db, delSQL, -1, &delStmt, nil)
            sqlite3_bind_text(delStmt, 1, (appName as NSString).utf8String, -1, nil)
            if sqlite3_step(delStmt) != SQLITE_DONE {
                let errMsg = String(cString: sqlite3_errmsg(db))
                print("[LearningDB] Delete patterns for app failed: \(errMsg)")
                sqlite3_finalize(delStmt)
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }
            sqlite3_finalize(delStmt)

            // Insert all new patterns
            let insertSQL = "INSERT INTO patterns (id, app_name, name, actions_json, frequency, first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?)"
            var insertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }

            let encoder = JSONEncoder()
            var transactionFailed = false
            for pattern in patterns {
                sqlite3_reset(insertStmt)
                let actionsJSON = String(data: (try? encoder.encode(pattern.actions)) ?? Data(), encoding: .utf8) ?? "[]"

                sqlite3_bind_text(insertStmt, 1, (pattern.id.uuidString as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 2, (pattern.appName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 3, (pattern.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 4, (actionsJSON as NSString).utf8String, -1, nil)
                sqlite3_bind_int(insertStmt, 5, Int32(pattern.frequency))
                sqlite3_bind_double(insertStmt, 6, pattern.firstSeen.timeIntervalSince1970)
                sqlite3_bind_double(insertStmt, 7, pattern.lastSeen.timeIntervalSince1970)
                if sqlite3_step(insertStmt) != SQLITE_DONE {
                    let errMsg = String(cString: sqlite3_errmsg(db))
                    print("[LearningDB] Batch replace pattern failed: \(errMsg)")
                    transactionFailed = true
                    break
                }
            }

            sqlite3_finalize(insertStmt)
            if transactionFailed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            } else {
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
            }
        }
    }

    // MARK: - Aggregation

    func allAppNames() -> [(name: String, patternCount: Int, observationCount: Int)] {
        queue.sync {
            let sql = """
            SELECT DISTINCT app_name,
                (SELECT COUNT(*) FROM patterns p WHERE p.app_name = o.app_name) as pattern_count,
                COUNT(*) as obs_count
            FROM observations o GROUP BY app_name ORDER BY obs_count DESC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var results: [(String, Int, Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let patterns = Int(sqlite3_column_int(stmt, 1))
                let obs = Int(sqlite3_column_int(stmt, 2))
                results.append((name, patterns, obs))
            }
            return results
        }
    }

    // MARK: - Pruning

    func pruneObservations(olderThanDays days: Int) {
        queue.sync {
            let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
            let sql = "DELETE FROM observations WHERE timestamp < ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, cutoff)
            if sqlite3_step(stmt) == SQLITE_DONE {
                let deleted = sqlite3_changes(db)
                if deleted > 0 {
                    print("[LearningDB] Pruned \(deleted) old observations")
                }
            }
        }
    }

    // MARK: - Cleanup

    func deleteAllData() {
        queue.sync {
            sqlite3_exec(db, "DELETE FROM observations", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM patterns", nil, nil, nil)
            print("[LearningDB] All data deleted")
        }
    }

    func deleteApp(_ appName: String) {
        queue.sync {
            var stmt: OpaquePointer?

            let sql1 = "DELETE FROM observations WHERE app_name = ?"
            sqlite3_prepare_v2(db, sql1, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, (appName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            let sql2 = "DELETE FROM patterns WHERE app_name = ?"
            sqlite3_prepare_v2(db, sql2, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, (appName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Episodes

    /// Execute arbitrary SQL with typed bindings. Used by EpisodeLogger and LearningFeedbackLoop.
    func executeSQL(_ sql: String, bindings: [Any?]) {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[LearningDB] executeSQL prepare failed for: \(sql.prefix(80))")
                return
            }

            for (i, binding) in bindings.enumerated() {
                let idx = Int32(i + 1)
                switch binding {
                case let s as String:
                    sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, nil)
                case let d as Double:
                    sqlite3_bind_double(stmt, idx, d)
                case let n as Int:
                    sqlite3_bind_int(stmt, idx, Int32(n))
                case nil:
                    sqlite3_bind_null(stmt, idx)
                default:
                    if let desc = binding.map({ "\($0)" }) {
                        sqlite3_bind_text(stmt, idx, (desc as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(stmt, idx)
                    }
                }
            }
            sqlite3_step(stmt)
        }
    }

    /// Query episodes by keyword similarity to a goal string.
    func queryEpisodes(goalQuery: String, limit: Int = 5) -> [(id: String, goal: String, outcome: String, failureReason: String?, whatWorked: String?, toolCount: Int)] {
        queue.sync {
            let sql = "SELECT id, goal, outcome, failure_reason, what_worked, tool_count FROM episodes ORDER BY timestamp DESC LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit * 5)) // fetch extra for filtering

            let queryWords = Set(goalQuery.lowercased().split(separator: " ").filter { $0.count > 2 }.map(String.init))

            var results: [(id: String, goal: String, outcome: String, failureReason: String?, whatWorked: String?, toolCount: Int)] = []

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let goal = String(cString: sqlite3_column_text(stmt, 1))
                let goalWords = Set(goal.lowercased().split(separator: " ").filter { $0.count > 2 }.map(String.init))
                let overlap = queryWords.intersection(goalWords).count
                guard overlap >= 1 else { continue }

                let outcome = String(cString: sqlite3_column_text(stmt, 2))
                let failureReason = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let whatWorked = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let toolCount = Int(sqlite3_column_int(stmt, 5))

                results.append((id, goal, outcome, failureReason, whatWorked, toolCount))
                if results.count >= limit { break }
            }
            return results
        }
    }

    /// Query learned rules above a confidence threshold.
    func queryRules(minConfidence: Double = 0.5, limit: Int = 10) -> [String] {
        queue.sync {
            let sql = "SELECT rule_text FROM learned_rules WHERE confidence >= ? ORDER BY confidence DESC, times_applied DESC LIMIT ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_double(stmt, 1, minConfidence)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var results: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return results
        }
    }

    /// Check if a rule already exists for a given source pattern.
    func hasRuleForPattern(patternId: String) -> Bool {
        queue.sync {
            let sql = "SELECT COUNT(*) FROM learned_rules WHERE source_pattern_id = ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            sqlite3_bind_text(stmt, 1, (patternId as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int(stmt, 0) > 0
        }
    }

    // MARK: - At-Rest Encryption

    /// Encrypt the database file when the app closes.
    /// Call from LearningManager.stop().
    func encryptAtRest() {
        queue.sync {
            // Close the database connection first
            sqlite3_close(db)
            db = nil
        }

        let fm = FileManager.default
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent(LearningConstants.appSupportSubdirectory, isDirectory: true)
        let dbPath = dir.appendingPathComponent(LearningConstants.databaseFilename)

        guard let plainData = try? Data(contentsOf: dbPath) else {
            print("[LearningDB] Cannot read database file for encryption")
            return
        }

        do {
            try SecureStorage.writeEncrypted(plainData, to: dbPath)
            print("[LearningDB] Database encrypted at rest")
        } catch {
            print("[LearningDB] Encryption failed: \(error)")
        }
    }

    /// Decrypt the database file when the app opens.
    /// Called automatically during init.
    private func decryptForUse(at path: String) {
        let url = URL(fileURLWithPath: path)

        // Check if the file is encrypted (SQLite files start with "SQLite format 3\0")
        guard let header = try? Data(contentsOf: url).prefix(16) else { return }
        let sqliteHeader = "SQLite format 3\0".data(using: .utf8)!

        if header != sqliteHeader.prefix(16) {
            // File appears encrypted — try to decrypt
            do {
                let decrypted = try SecureStorage.readEncrypted(from: url)
                try decrypted.write(to: url, options: .atomic)
                print("[LearningDB] Database decrypted for use")
            } catch {
                print("[LearningDB] Decryption failed, database may be corrupted: \(error)")
                // Delete and start fresh
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    deinit {
        sqlite3_close(db)
    }
}
