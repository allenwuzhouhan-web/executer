import Foundation
import SQLite3

/// Short-term memory: stores ALL raw observation events from all observers.
/// Retention: 30 days. Events older than that should have been processed into beliefs.
/// Location: ~/Library/Application Support/Executer/observations.db
final class ObservationStore {
    static let shared = ObservationStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.executer.observationstore", qos: .utility)

    /// Write buffer — events accumulate here and flush every 30 seconds
    /// or when the buffer hits 100 events, whichever comes first.
    private var writeBuffer: [OEObservation] = []
    private let bufferLock = NSLock()
    private var flushTimer: DispatchSourceTimer?

    private let dbPath: URL

    private init() {
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("[ObservationStore] Cannot find Application Support directory")
            dbPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("observations.db")
            return
        }
        let dir = appSupportDir.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("observations.db")

        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            print("[ObservationStore] Failed to open database")
            return
        }

        configurePragmas()
        createSchema()
        startFlushTimer()
    }

    private func configurePragmas() {
        queue.sync {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA mmap_size=134217728", nil, nil, nil)   // 128MB
            sqlite3_exec(db, "PRAGMA cache_size=-32000", nil, nil, nil)     // 32MB
            sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        }
    }

    private func createSchema() {
        queue.sync {
            let sql = """
            CREATE TABLE IF NOT EXISTS observations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                observer_type TEXT NOT NULL,
                event_data TEXT NOT NULL,
                interaction_weight REAL DEFAULT 1.0,
                day_date TEXT NOT NULL,
                hour_of_day INTEGER NOT NULL,
                day_of_week INTEGER NOT NULL,
                focus_mode TEXT,
                processed INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_obs_timestamp ON observations(timestamp);
            CREATE INDEX IF NOT EXISTS idx_obs_type ON observations(observer_type);
            CREATE INDEX IF NOT EXISTS idx_obs_day ON observations(day_date);
            CREATE INDEX IF NOT EXISTS idx_obs_processed ON observations(processed);
            CREATE INDEX IF NOT EXISTS idx_obs_type_day ON observations(observer_type, day_date);
            """
            var errmsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "unknown"
                print("[ObservationStore] Schema error: \(msg)")
                sqlite3_free(errmsg)
            }
        }
    }

    // MARK: - Buffered Writes

    /// Buffer an observation for batch insertion.
    func record(_ observation: OEObservation) {
        bufferLock.lock()
        writeBuffer.append(observation)
        let shouldFlush = writeBuffer.count >= 100
        bufferLock.unlock()

        if shouldFlush {
            flush()
        }
    }

    /// Batch-insert all buffered observations in a single transaction.
    func flush() {
        bufferLock.lock()
        guard !writeBuffer.isEmpty else {
            bufferLock.unlock()
            return
        }
        let batch = writeBuffer
        writeBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()

        queue.async { [weak self] in
            self?.insertBatch(batch)
        }
    }

    private func insertBatch(_ batch: [OEObservation]) {
        // dispatchPrecondition: already on self.queue via async call
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let sql = """
        INSERT INTO observations (timestamp, observer_type, event_data, interaction_weight, day_date, hour_of_day, day_of_week, focus_mode)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }

        let calendar = Calendar.current
        let dateFormatter = Self.dayDateFormatter

        for obs in batch {
            sqlite3_reset(stmt)

            let ts = obs.timestamp
            let components = calendar.dateComponents([.hour, .weekday], from: ts)
            let hour = components.hour ?? 0
            // Convert Calendar weekday (Sun=1..Sat=7) to ISO (Mon=1..Sun=7)
            let calWeekday = components.weekday ?? 1
            let isoWeekday = calWeekday == 1 ? 7 : calWeekday - 1
            let dayDate = dateFormatter.string(from: ts)

            sqlite3_bind_double(stmt, 1, ts.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (obs.observerType.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (obs.encodeEventData() as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, obs.interactionWeight)
            sqlite3_bind_text(stmt, 5, (dayDate as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 6, Int32(hour))
            sqlite3_bind_int(stmt, 7, Int32(isoWeekday))

            if let fm = obs.focusMode {
                sqlite3_bind_text(stmt, 8, (fm as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 8)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                let err = String(cString: sqlite3_errmsg(db))
                print("[ObservationStore] Insert failed: \(err)")
                break
            }
        }

        sqlite3_finalize(stmt)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Queries (used by PatternRecognizer)

    /// Fetch unprocessed observations, optionally filtered by type.
    func fetchUnprocessed(type: ObserverType? = nil, limit: Int = 5000) -> [(id: Int, json: String, weight: Double, dayDate: String, hour: Int, dayOfWeek: Int, focusMode: String?)] {
        queue.sync {
            var sql = "SELECT id, event_data, interaction_weight, day_date, hour_of_day, day_of_week, focus_mode FROM observations WHERE processed = 0"
            if let type = type {
                sql += " AND observer_type = '\(type.rawValue)'"
            }
            sql += " ORDER BY timestamp ASC LIMIT \(limit)"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var results: [(Int, String, Double, String, Int, Int, String?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let json = String(cString: sqlite3_column_text(stmt, 1))
                let weight = sqlite3_column_double(stmt, 2)
                let day = String(cString: sqlite3_column_text(stmt, 3))
                let hour = Int(sqlite3_column_int(stmt, 4))
                let dow = Int(sqlite3_column_int(stmt, 5))
                let fm = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                results.append((id, json, weight, day, hour, dow, fm))
            }
            return results
        }
    }

    /// Mark observations as processed by the PatternRecognizer.
    func markProcessed(ids: [Int]) {
        guard !ids.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let sql = "UPDATE observations SET processed = 1 WHERE id IN (\(placeholders))"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int(stmt, Int32(i + 1), Int32(id))
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Count observations grouped by type and day. Used for pattern detection.
    func countByTypeAndDay(type: ObserverType, days: Int = 30) -> [(dayDate: String, count: Int)] {
        queue.sync {
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            let cutoffStr = Self.dayDateFormatter.string(from: cutoff)
            let sql = "SELECT day_date, COUNT(*) FROM observations WHERE observer_type = ? AND day_date >= ? GROUP BY day_date ORDER BY day_date"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, (type.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (cutoffStr as NSString).utf8String, -1, nil)

            var results: [(String, Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let day = String(cString: sqlite3_column_text(stmt, 0))
                let count = Int(sqlite3_column_int(stmt, 1))
                results.append((day, count))
            }
            return results
        }
    }

    /// Fetch all observations for a specific day and type. Used by PatternRecognizer.
    func fetchForDay(_ dayDate: String, type: ObserverType) -> [(json: String, weight: Double, hour: Int)] {
        queue.sync {
            let sql = "SELECT event_data, interaction_weight, hour_of_day FROM observations WHERE day_date = ? AND observer_type = ? AND interaction_weight > 0 ORDER BY timestamp"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, (dayDate as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (type.rawValue as NSString).utf8String, -1, nil)

            var results: [(String, Double, Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let json = String(cString: sqlite3_column_text(stmt, 0))
                let weight = sqlite3_column_double(stmt, 1)
                let hour = Int(sqlite3_column_int(stmt, 2))
                results.append((json, weight, hour))
            }
            return results
        }
    }

    /// Get distinct days that have observations.
    func distinctDays(type: ObserverType? = nil, recentDays: Int = 30) -> [String] {
        queue.sync {
            let cutoff = Calendar.current.date(byAdding: .day, value: -recentDays, to: Date()) ?? Date()
            let cutoffStr = Self.dayDateFormatter.string(from: cutoff)
            var sql = "SELECT DISTINCT day_date FROM observations WHERE day_date >= ?"
            if let type = type {
                sql += " AND observer_type = '\(type.rawValue)'"
            }
            sql += " ORDER BY day_date"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, (cutoffStr as NSString).utf8String, -1, nil)

            var results: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return results
        }
    }

    // MARK: - Cleanup

    /// Delete observations older than the retention period (30 days).
    func pruneOldObservations(retentionDays: Int = 30) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let cutoff = Date().timeIntervalSince1970 - Double(retentionDays) * 86400
            let sql = "DELETE FROM observations WHERE timestamp < ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            let deleted = sqlite3_changes(self.db)
            if deleted > 0 {
                print("[ObservationStore] Pruned \(deleted) old observations")
                sqlite3_exec(self.db, "PRAGMA incremental_vacuum", nil, nil, nil)
            }
        }
    }

    /// Total observation count (for diagnostics).
    func totalCount() -> Int {
        queue.sync {
            let sql = "SELECT COUNT(*) FROM observations"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// Database size in bytes.
    func databaseSizeBytes() -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: dbPath.path))?[.size] as? Int64 ?? 0
    }

    // MARK: - Lifecycle

    func shutdown() {
        flush()
        flushTimer?.cancel()
        flushTimer = nil
        queue.sync {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - Internals

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        flushTimer = timer
    }

    static let dayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    deinit {
        flushTimer?.cancel()
        sqlite3_close(db)
    }
}
