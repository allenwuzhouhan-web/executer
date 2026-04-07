import Foundation
import SQLite3

/// Long-term memory: stores learned patterns (beliefs) about the user.
/// Beliefs have confidence scores, decay over time, and can be vetoed/boosted.
/// Location: ~/Library/Application Support/Executer/beliefs.db
final class BeliefStore {
    static let shared = BeliefStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.executer.beliefstore", qos: .utility)

    private init() {
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("[BeliefStore] Cannot find Application Support directory")
            return
        }
        let dir = appSupportDir.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("beliefs.db").path

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            print("[BeliefStore] Failed to open database")
            return
        }
        configurePragmas()
        createSchema()
    }

    private func configurePragmas() {
        queue.sync {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA mmap_size=67108864", nil, nil, nil)    // 64MB
            sqlite3_exec(db, "PRAGMA cache_size=-16000", nil, nil, nil)     // 16MB
            sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        }
    }

    private func createSchema() {
        queue.sync {
            let sql = """
            CREATE TABLE IF NOT EXISTS beliefs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                pattern_type TEXT NOT NULL,
                description TEXT NOT NULL,
                pattern_data TEXT NOT NULL,
                confidence REAL NOT NULL,
                classification TEXT NOT NULL,
                first_observed TEXT NOT NULL,
                last_observed TEXT NOT NULL,
                observation_count INTEGER NOT NULL,
                distinct_days INTEGER NOT NULL,
                vetoed INTEGER DEFAULT 0,
                boosted INTEGER DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_beliefs_type ON beliefs(pattern_type);
            CREATE INDEX IF NOT EXISTS idx_beliefs_confidence ON beliefs(confidence);
            CREATE INDEX IF NOT EXISTS idx_beliefs_classification ON beliefs(classification);
            CREATE INDEX IF NOT EXISTS idx_beliefs_vetoed ON beliefs(vetoed);

            CREATE TABLE IF NOT EXISTS corrections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                belief_id INTEGER NOT NULL,
                correction_type TEXT NOT NULL,
                user_statement TEXT,
                timestamp REAL NOT NULL,
                FOREIGN KEY (belief_id) REFERENCES beliefs(id)
            );
            CREATE INDEX IF NOT EXISTS idx_corrections_belief ON corrections(belief_id);
            """
            var errmsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "unknown"
                print("[BeliefStore] Schema error: \(msg)")
                sqlite3_free(errmsg)
            }
        }
    }

    // MARK: - Insert / Update Beliefs

    /// Insert a new belief or update an existing one with matching pattern_type + description.
    func upsertBelief(
        patternType: PatternType,
        description: String,
        patternData: String,
        confidence: Double,
        observationCount: Int,
        distinctDays: Int,
        lastObserved: String
    ) {
        queue.sync {
            // Check for existing belief with same type and description
            let checkSQL = "SELECT id, observation_count, distinct_days, vetoed FROM beliefs WHERE pattern_type = ? AND description = ? LIMIT 1"
            var checkStmt: OpaquePointer?
            sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil)
            sqlite3_bind_text(checkStmt, 1, (patternType.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(checkStmt, 2, (description as NSString).utf8String, -1, nil)

            if sqlite3_step(checkStmt) == SQLITE_ROW {
                let existingId = Int(sqlite3_column_int(checkStmt, 0))
                let existingCount = Int(sqlite3_column_int(checkStmt, 1))
                let existingDays = Int(sqlite3_column_int(checkStmt, 2))
                let isVetoed = sqlite3_column_int(checkStmt, 3) != 0
                sqlite3_finalize(checkStmt)

                // Principle 7: vetoed beliefs are NEVER updated
                guard !isVetoed else { return }

                let newCount = existingCount + observationCount
                let newDays = max(existingDays, distinctDays)
                let classification = BeliefClassification.from(confidence: confidence)

                let updateSQL = """
                UPDATE beliefs SET pattern_data = ?, confidence = ?, classification = ?,
                    last_observed = ?, observation_count = ?, distinct_days = ?, updated_at = ?
                WHERE id = ?
                """
                var updateStmt: OpaquePointer?
                sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil)
                sqlite3_bind_text(updateStmt, 1, (patternData as NSString).utf8String, -1, nil)
                sqlite3_bind_double(updateStmt, 2, confidence)
                sqlite3_bind_text(updateStmt, 3, (classification.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(updateStmt, 4, (lastObserved as NSString).utf8String, -1, nil)
                sqlite3_bind_int(updateStmt, 5, Int32(newCount))
                sqlite3_bind_int(updateStmt, 6, Int32(newDays))
                sqlite3_bind_double(updateStmt, 7, Date().timeIntervalSince1970)
                sqlite3_bind_int(updateStmt, 8, Int32(existingId))
                sqlite3_step(updateStmt)
                sqlite3_finalize(updateStmt)
            } else {
                sqlite3_finalize(checkStmt)

                // Insert new
                let classification = BeliefClassification.from(confidence: confidence)
                let now = Date().timeIntervalSince1970
                let insertSQL = """
                INSERT INTO beliefs (pattern_type, description, pattern_data, confidence, classification,
                    first_observed, last_observed, observation_count, distinct_days, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                var insertStmt: OpaquePointer?
                sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil)
                sqlite3_bind_text(insertStmt, 1, (patternType.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 2, (description as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 3, (patternData as NSString).utf8String, -1, nil)
                sqlite3_bind_double(insertStmt, 4, confidence)
                sqlite3_bind_text(insertStmt, 5, (classification.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 6, (lastObserved as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStmt, 7, (lastObserved as NSString).utf8String, -1, nil)
                sqlite3_bind_int(insertStmt, 8, Int32(observationCount))
                sqlite3_bind_int(insertStmt, 9, Int32(distinctDays))
                sqlite3_bind_double(insertStmt, 10, now)
                sqlite3_bind_double(insertStmt, 11, now)
                sqlite3_step(insertStmt)
                sqlite3_finalize(insertStmt)
            }
        }
    }

    // MARK: - Query Beliefs

    /// Fetch beliefs filtered by type and minimum confidence.
    func query(type: PatternType? = nil, minConfidence: Double = 0.7, limit: Int = 50) -> [Belief] {
        queue.sync {
            var sql = "SELECT id, pattern_type, description, pattern_data, confidence, classification, first_observed, last_observed, observation_count, distinct_days, vetoed, boosted, created_at, updated_at FROM beliefs WHERE vetoed = 0 AND confidence >= ?"
            if let type = type {
                sql += " AND pattern_type = '\(type.rawValue)'"
            }
            sql += " ORDER BY confidence DESC LIMIT \(limit)"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_double(stmt, 1, minConfidence)

            return readBeliefs(from: stmt)
        }
    }

    /// Fetch ALL beliefs including hypotheses and noise (for the "what do you know" report).
    func allBeliefs() -> [Belief] {
        queue.sync {
            let sql = "SELECT id, pattern_type, description, pattern_data, confidence, classification, first_observed, last_observed, observation_count, distinct_days, vetoed, boosted, created_at, updated_at FROM beliefs ORDER BY confidence DESC"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            return readBeliefs(from: stmt)
        }
    }

    /// Fetch beliefs that are hypotheses (0.3–0.7 confidence).
    func hypotheses() -> [Belief] {
        queue.sync {
            let sql = "SELECT id, pattern_type, description, pattern_data, confidence, classification, first_observed, last_observed, observation_count, distinct_days, vetoed, boosted, created_at, updated_at FROM beliefs WHERE vetoed = 0 AND classification = 'hypothesis' ORDER BY confidence DESC"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            return readBeliefs(from: stmt)
        }
    }

    private func readBeliefs(from stmt: OpaquePointer?) -> [Belief] {
        var results: [Belief] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let belief = Belief(
                id: Int(sqlite3_column_int(stmt, 0)),
                patternType: PatternType(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .preference,
                description: String(cString: sqlite3_column_text(stmt, 2)),
                patternData: String(cString: sqlite3_column_text(stmt, 3)),
                confidence: sqlite3_column_double(stmt, 4),
                classification: BeliefClassification(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .noise,
                firstObserved: String(cString: sqlite3_column_text(stmt, 6)),
                lastObserved: String(cString: sqlite3_column_text(stmt, 7)),
                observationCount: Int(sqlite3_column_int(stmt, 8)),
                distinctDays: Int(sqlite3_column_int(stmt, 9)),
                vetoed: sqlite3_column_int(stmt, 10) != 0,
                boosted: sqlite3_column_int(stmt, 11) != 0,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
            )
            results.append(belief)
        }
        return results
    }

    // MARK: - User Corrections (Principle 7)

    /// Veto: user says "that's not a pattern" → permanently suppress.
    func vetoBelief(id: Int, userStatement: String?) {
        queue.sync {
            let sql = "UPDATE beliefs SET vetoed = 1, updated_at = ? WHERE id = ?"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(id))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            logCorrection(beliefId: id, type: "veto", statement: userStatement)
        }
    }

    /// Boost: user says "yes, I always do that" → confidence = 1.0 immediately.
    func boostBelief(id: Int, userStatement: String?) {
        queue.sync {
            let sql = "UPDATE beliefs SET boosted = 1, confidence = 1.0, classification = 'belief', updated_at = ? WHERE id = ?"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(id))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            logCorrection(beliefId: id, type: "boost", statement: userStatement)
        }
    }

    private func logCorrection(beliefId: Int, type: String, statement: String?) {
        let sql = "INSERT INTO corrections (belief_id, correction_type, user_statement, timestamp) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        sqlite3_bind_int(stmt, 1, Int32(beliefId))
        sqlite3_bind_text(stmt, 2, (type as NSString).utf8String, -1, nil)
        if let s = statement {
            sqlite3_bind_text(stmt, 3, (s as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - Decay (Principle 5)

    /// Apply exponential decay to all non-vetoed, non-boosted beliefs.
    /// Called daily by DecayEngine. Returns number of beliefs reclassified.
    func applyDecay() -> Int {
        queue.sync {
            let sql = "SELECT id, confidence, last_observed, classification FROM beliefs WHERE vetoed = 0 AND boosted = 0"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

            struct DecayUpdate {
                let id: Int
                let newConfidence: Double
                let newClassification: BeliefClassification
            }

            var updates: [DecayUpdate] = []
            let today = Date()
            let formatter = ObservationStore.dayDateFormatter

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let confidence = sqlite3_column_double(stmt, 1)
                let lastObsStr = String(cString: sqlite3_column_text(stmt, 2))

                guard let lastObsDate = formatter.date(from: lastObsStr) else { continue }
                let daysSince = today.timeIntervalSince(lastObsDate) / 86400.0

                // Exponential decay: λ = ln(2)/14 ≈ 0.0495
                // Half-life of 14 days: an observation from 2 weeks ago has half the weight.
                let decayFactor = exp(-0.0495 * daysSince)
                let newConfidence = confidence * decayFactor
                let newClass = BeliefClassification.from(confidence: newConfidence)

                updates.append(DecayUpdate(id: id, newConfidence: newConfidence, newClassification: newClass))
            }
            sqlite3_finalize(stmt)

            // Apply updates
            var reclassified = 0
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            let updateSQL = "UPDATE beliefs SET confidence = ?, classification = ?, updated_at = ? WHERE id = ?"
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return 0
            }

            for u in updates {
                sqlite3_reset(updateStmt)
                sqlite3_bind_double(updateStmt, 1, u.newConfidence)
                sqlite3_bind_text(updateStmt, 2, (u.newClassification.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_double(updateStmt, 3, today.timeIntervalSince1970)
                sqlite3_bind_int(updateStmt, 4, Int32(u.id))
                sqlite3_step(updateStmt)
                reclassified += 1
            }

            sqlite3_finalize(updateStmt)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            return reclassified
        }
    }

    /// Garbage collect noise beliefs older than 30 days.
    func garbageCollectNoise(olderThanDays: Int = 30) -> Int {
        queue.sync {
            let cutoff = Date().timeIntervalSince1970 - Double(olderThanDays) * 86400
            let sql = "DELETE FROM beliefs WHERE classification = 'noise' AND vetoed = 0 AND updated_at < ?"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Forget (Privacy)

    /// User says "forget everything about [topic]" → find and delete related beliefs.
    func forgetTopic(_ topic: String) -> Int {
        queue.sync {
            let pattern = "%\(topic)%"
            let sql = "DELETE FROM beliefs WHERE description LIKE ? OR pattern_data LIKE ?"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (pattern as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Stats

    func beliefCount() -> (beliefs: Int, hypotheses: Int, noise: Int) {
        queue.sync {
            var beliefs = 0, hypotheses = 0, noise = 0
            let sql = "SELECT classification, COUNT(*) FROM beliefs WHERE vetoed = 0 GROUP BY classification"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cls = String(cString: sqlite3_column_text(stmt, 0))
                let count = Int(sqlite3_column_int(stmt, 1))
                switch cls {
                case "belief": beliefs = count
                case "hypothesis": hypotheses = count
                case "noise": noise = count
                default: break
                }
            }
            return (beliefs, hypotheses, noise)
        }
    }

    // MARK: - Lifecycle

    func shutdown() {
        queue.sync {
            sqlite3_close(db)
            db = nil
        }
    }

    // Expose day formatter for use by DecayEngine
    static let dayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    deinit {
        sqlite3_close(db)
    }
}

// Removed duplicate ObservationStore extension — formatter is already defined in ObservationStore.swift
