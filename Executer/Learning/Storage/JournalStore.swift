import Foundation
import SQLite3

/// SQLite-backed persistent storage for workflow journals.
/// Uses a separate `journals.db` file to keep journal data isolated
/// from the learning observations database, following the same
/// WAL-mode + DispatchQueue patterns as LearningDatabase.
final class JournalStore {
    static let shared = JournalStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.executer.journalstore", qos: .utility)

    private init() {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent(LearningConstants.appSupportSubdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("journals.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[JournalStore] Failed to open, recreating")
            try? FileManager.default.removeItem(atPath: dbPath)
            if sqlite3_open(dbPath, &db) != SQLITE_OK {
                print("[JournalStore] Fatal: cannot create database")
                return
            }
        }

        configurePragmas()
        createSchema()
    }

    private func configurePragmas() {
        queue.sync {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA auto_vacuum=INCREMENTAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            // M-series optimizations
            sqlite3_exec(db, "PRAGMA mmap_size=268435456", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA cache_size=-64000", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        }
    }

    private func createSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS workflow_journals (
            id TEXT PRIMARY KEY,
            task_description TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'active',
            apps_json TEXT NOT NULL DEFAULT '[]',
            topic_terms_json TEXT NOT NULL DEFAULT '[]',
            start_time REAL NOT NULL,
            end_time REAL NOT NULL,
            entry_count INTEGER NOT NULL DEFAULT 0,
            boundary_id TEXT,
            closing_boundary_id TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_journal_status ON workflow_journals(status);
        CREATE INDEX IF NOT EXISTS idx_journal_start ON workflow_journals(start_time);
        CREATE INDEX IF NOT EXISTS idx_journal_end ON workflow_journals(end_time);

        CREATE TABLE IF NOT EXISTS journal_entries (
            id TEXT PRIMARY KEY,
            journal_id TEXT NOT NULL,
            timestamp REAL NOT NULL,
            semantic_action TEXT NOT NULL,
            app_context TEXT NOT NULL,
            window_context TEXT NOT NULL DEFAULT '',
            element_context TEXT NOT NULL DEFAULT '',
            intent_category TEXT NOT NULL DEFAULT 'unknown',
            source_type TEXT NOT NULL,
            topic_terms_json TEXT NOT NULL DEFAULT '[]',
            confidence REAL NOT NULL DEFAULT 0.5,
            FOREIGN KEY (journal_id) REFERENCES workflow_journals(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_entry_journal ON journal_entries(journal_id, timestamp);
        CREATE INDEX IF NOT EXISTS idx_entry_time ON journal_entries(timestamp);

        -- Phase 4: Generalized workflows produced from journals
        CREATE TABLE IF NOT EXISTS generalized_workflows (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            steps_json TEXT NOT NULL,
            parameters_json TEXT NOT NULL DEFAULT '[]',
            applicability_json TEXT NOT NULL,
            source_journal_id TEXT,
            category TEXT NOT NULL DEFAULT 'other',
            confidence REAL NOT NULL DEFAULT 0.5,
            created_at REAL NOT NULL,
            times_used INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (source_journal_id) REFERENCES workflow_journals(id) ON DELETE SET NULL
        );
        CREATE INDEX IF NOT EXISTS idx_gw_category ON generalized_workflows(category);
        CREATE INDEX IF NOT EXISTS idx_gw_created ON generalized_workflows(created_at);
        CREATE INDEX IF NOT EXISTS idx_gw_source ON generalized_workflows(source_journal_id);
        """

        queue.sync {
            var errmsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "unknown"
                print("[JournalStore] Schema error: \(msg)")
                sqlite3_free(errmsg)
            }
        }
    }

    // MARK: - Journal CRUD

    /// Insert a new journal.
    func insertJournal(_ journal: WorkflowJournal) {
        queue.sync {
            let sql = """
            INSERT OR REPLACE INTO workflow_journals
                (id, task_description, status, apps_json, topic_terms_json, start_time, end_time, entry_count, boundary_id, closing_boundary_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            bindText(stmt, 1, journal.id.uuidString)
            bindText(stmt, 2, journal.taskDescription)
            bindText(stmt, 3, journal.status.rawValue)
            bindText(stmt, 4, encodeJSON(journal.apps))
            bindText(stmt, 5, encodeJSON(journal.topicTerms))
            sqlite3_bind_double(stmt, 6, journal.startTime.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 7, journal.endTime.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 8, Int32(journal.entries.count))
            if let bid = journal.boundaryId { bindText(stmt, 9, bid.uuidString) } else { sqlite3_bind_null(stmt, 9) }
            if let cbid = journal.closingBoundaryId { bindText(stmt, 10, cbid.uuidString) } else { sqlite3_bind_null(stmt, 10) }

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[JournalStore] Insert journal failed: \(errorMessage())")
            }
        }
    }

    /// Update an existing journal's metadata (status, description, end_time, entry_count).
    func updateJournal(_ journal: WorkflowJournal) {
        queue.sync {
            let sql = """
            UPDATE workflow_journals SET
                task_description = ?, status = ?, apps_json = ?, topic_terms_json = ?,
                end_time = ?, entry_count = ?, closing_boundary_id = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            bindText(stmt, 1, journal.taskDescription)
            bindText(stmt, 2, journal.status.rawValue)
            bindText(stmt, 3, encodeJSON(journal.apps))
            bindText(stmt, 4, encodeJSON(journal.topicTerms))
            sqlite3_bind_double(stmt, 5, journal.endTime.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 6, Int32(journal.entries.count))
            if let cbid = journal.closingBoundaryId { bindText(stmt, 7, cbid.uuidString) } else { sqlite3_bind_null(stmt, 7) }
            bindText(stmt, 8, journal.id.uuidString)

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[JournalStore] Update journal failed: \(errorMessage())")
            }
        }
    }

    // MARK: - Entry Operations

    /// Insert a single journal entry.
    func insertEntry(_ entry: JournalEntry, journalId: UUID) {
        queue.sync {
            let sql = """
            INSERT INTO journal_entries
                (id, journal_id, timestamp, semantic_action, app_context, window_context, element_context, intent_category, source_type, topic_terms_json, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            bindText(stmt, 1, entry.id.uuidString)
            bindText(stmt, 2, journalId.uuidString)
            sqlite3_bind_double(stmt, 3, entry.timestamp.timeIntervalSince1970)
            bindText(stmt, 4, entry.semanticAction)
            bindText(stmt, 5, entry.appContext)
            bindText(stmt, 6, entry.windowContext)
            bindText(stmt, 7, entry.elementContext)
            bindText(stmt, 8, entry.intentCategory)
            bindText(stmt, 9, entry.sourceType.rawValue)
            bindText(stmt, 10, encodeJSON(entry.topicTerms))
            sqlite3_bind_double(stmt, 11, entry.confidence)

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[JournalStore] Insert entry failed: \(errorMessage())")
            }
        }
    }

    /// Batch insert entries for a journal.
    func insertEntries(_ entries: [JournalEntry], journalId: UUID) {
        guard !entries.isEmpty else { return }
        queue.sync {
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            let sql = """
            INSERT INTO journal_entries
                (id, journal_id, timestamp, semantic_action, app_context, window_context, element_context, intent_category, source_type, topic_terms_json, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }

            for entry in entries {
                sqlite3_reset(stmt)
                bindText(stmt, 1, entry.id.uuidString)
                bindText(stmt, 2, journalId.uuidString)
                sqlite3_bind_double(stmt, 3, entry.timestamp.timeIntervalSince1970)
                bindText(stmt, 4, entry.semanticAction)
                bindText(stmt, 5, entry.appContext)
                bindText(stmt, 6, entry.windowContext)
                bindText(stmt, 7, entry.elementContext)
                bindText(stmt, 8, entry.intentCategory)
                bindText(stmt, 9, entry.sourceType.rawValue)
                bindText(stmt, 10, encodeJSON(entry.topicTerms))
                sqlite3_bind_double(stmt, 11, entry.confidence)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    print("[JournalStore] Batch entry insert failed: \(errorMessage())")
                }
            }

            sqlite3_finalize(stmt)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    // MARK: - Queries

    /// Fetch recent closed journals (for recall, display, etc).
    func recentJournals(limit: Int = 50, status: WorkflowJournal.Status? = nil) -> [WorkflowJournal] {
        queue.sync {
            var sql = "SELECT id, task_description, status, apps_json, topic_terms_json, start_time, end_time, entry_count, boundary_id, closing_boundary_id FROM workflow_journals"
            if let status = status {
                sql += " WHERE status = '\(status.rawValue)'"
            }
            sql += " ORDER BY start_time DESC LIMIT \(limit)"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var results: [WorkflowJournal] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let journal = readJournalRow(stmt) {
                    results.append(journal)
                }
            }
            return results
        }
    }

    /// Fetch entries for a specific journal.
    func entries(forJournalId journalId: UUID) -> [JournalEntry] {
        queue.sync {
            let sql = "SELECT id, timestamp, semantic_action, app_context, window_context, element_context, intent_category, source_type, topic_terms_json, confidence FROM journal_entries WHERE journal_id = ? ORDER BY timestamp ASC"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, journalId.uuidString)

            var results: [JournalEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let entry = readEntryRow(stmt) {
                    results.append(entry)
                }
            }
            return results
        }
    }

    /// Count of journals by status.
    func journalCount(status: WorkflowJournal.Status? = nil) -> Int {
        queue.sync {
            var sql = "SELECT COUNT(*) FROM workflow_journals"
            if let status = status { sql += " WHERE status = '\(status.rawValue)'" }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - Generalized Workflows (Phase 4)

    /// Insert a generalized workflow.
    func insertGeneralizedWorkflow(_ workflow: GeneralizedWorkflow) {
        queue.sync {
            let sql = """
            INSERT OR REPLACE INTO generalized_workflows
                (id, name, description, steps_json, parameters_json, applicability_json, source_journal_id, category, confidence, created_at, times_used)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            bindText(stmt, 1, workflow.id.uuidString)
            bindText(stmt, 2, workflow.name)
            bindText(stmt, 3, workflow.description)
            bindText(stmt, 4, encodeEncodable(workflow.steps))
            bindText(stmt, 5, encodeEncodable(workflow.parameters))
            bindText(stmt, 6, encodeEncodable(workflow.applicability))
            if let sjid = workflow.sourceJournalId { bindText(stmt, 7, sjid.uuidString) } else { sqlite3_bind_null(stmt, 7) }
            bindText(stmt, 8, workflow.category)
            sqlite3_bind_double(stmt, 9, workflow.confidence)
            sqlite3_bind_double(stmt, 10, workflow.createdAt.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 11, Int32(workflow.timesUsed))

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[JournalStore] Insert generalized workflow failed: \(errorMessage())")
            }
        }
    }

    /// Fetch recent generalized workflows.
    func recentGeneralizedWorkflows(limit: Int = 50) -> [GeneralizedWorkflow] {
        queue.sync {
            let sql = "SELECT id, name, description, steps_json, parameters_json, applicability_json, source_journal_id, category, confidence, created_at, times_used FROM generalized_workflows ORDER BY created_at DESC LIMIT \(limit)"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var results: [GeneralizedWorkflow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let wf = readGeneralizedWorkflowRow(stmt) {
                    results.append(wf)
                }
            }
            return results
        }
    }

    /// Count of generalized workflows.
    func generalizedWorkflowCount() -> Int {
        queue.sync {
            let sql = "SELECT COUNT(*) FROM generalized_workflows"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    private func readGeneralizedWorkflowRow(_ stmt: OpaquePointer?) -> GeneralizedWorkflow? {
        let idStr = readString(stmt, 0)
        guard let id = UUID(uuidString: idStr) else { return nil }

        let name = readString(stmt, 1)
        let description = readString(stmt, 2)
        let stepsJson = readString(stmt, 3)
        let paramsJson = readString(stmt, 4)
        let applicabilityJson = readString(stmt, 5)
        let sourceJournalIdStr = readString(stmt, 6)
        let category = readString(stmt, 7)
        let confidence = sqlite3_column_double(stmt, 8)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let timesUsed = Int(sqlite3_column_int(stmt, 10))

        let steps: [AbstractStep] = decodeEncodable(stepsJson) ?? []
        let parameters: [WorkflowParameter] = decodeEncodable(paramsJson) ?? []
        guard let applicability: ApplicabilityCondition = decodeEncodable(applicabilityJson) else { return nil }

        var wf = GeneralizedWorkflow(
            name: name,
            description: description,
            steps: steps,
            parameters: parameters,
            applicability: applicability,
            sourceJournalId: UUID(uuidString: sourceJournalIdStr),
            category: category,
            confidence: confidence
        )
        wf.id = id
        wf.createdAt = createdAt
        wf.timesUsed = timesUsed
        return wf
    }

    // MARK: - Archival & Cleanup

    /// Archive journals older than the given number of days.
    /// Returns the number of journals archived.
    @discardableResult
    func archiveOldJournals(olderThanDays days: Int = 30) -> Int {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            let sql = "UPDATE workflow_journals SET status = 'archived' WHERE status = 'closed' AND end_time < ?"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    /// Delete archived journals and their entries older than the given number of days.
    /// Returns the number of journals purged.
    @discardableResult
    func purgeArchivedJournals(olderThanDays days: Int = 90) -> Int {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970

            // Delete entries first (foreign key)
            let deleteEntries = "DELETE FROM journal_entries WHERE journal_id IN (SELECT id FROM workflow_journals WHERE status = 'archived' AND end_time < ?)"
            var stmt1: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteEntries, -1, &stmt1, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt1, 1, cutoff)
                sqlite3_step(stmt1)
            }
            sqlite3_finalize(stmt1)

            // Delete journals
            let deleteJournals = "DELETE FROM workflow_journals WHERE status = 'archived' AND end_time < ?"
            var stmt2: OpaquePointer?
            defer { sqlite3_finalize(stmt2) }
            guard sqlite3_prepare_v2(db, deleteJournals, -1, &stmt2, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_double(stmt2, 1, cutoff)
            sqlite3_step(stmt2)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - SQLite Helpers

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func readString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private func errorMessage() -> String {
        guard let db = db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func encodeJSON(_ strings: [String]) -> String {
        (try? JSONEncoder().encode(strings)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private func decodeJSON(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func encodeEncodable<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func decodeEncodable<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func readJournalRow(_ stmt: OpaquePointer?) -> WorkflowJournal? {
        let idStr = readString(stmt, 0)
        guard let id = UUID(uuidString: idStr) else { return nil }

        let taskDescription = readString(stmt, 1)
        let statusStr = readString(stmt, 2)
        let apps = decodeJSON(readString(stmt, 3))
        let topicTerms = decodeJSON(readString(stmt, 4))
        let startTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let endTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let boundaryIdStr = readString(stmt, 8)
        let closingBoundaryIdStr = readString(stmt, 9)

        var journal = WorkflowJournal(
            boundaryId: UUID(uuidString: boundaryIdStr),
            firstApp: apps.first ?? "Unknown"
        )
        journal.id = id
        journal.taskDescription = taskDescription
        journal.status = WorkflowJournal.Status(rawValue: statusStr) ?? .closed
        journal.apps = apps
        journal.topicTerms = topicTerms
        journal.startTime = startTime
        journal.endTime = endTime
        journal.closingBoundaryId = UUID(uuidString: closingBoundaryIdStr)
        return journal
    }

    private func readEntryRow(_ stmt: OpaquePointer?) -> JournalEntry? {
        let idStr = readString(stmt, 0)
        guard let id = UUID(uuidString: idStr) else { return nil }

        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let semanticAction = readString(stmt, 2)
        let appContext = readString(stmt, 3)
        let windowContext = readString(stmt, 4)
        let elementContext = readString(stmt, 5)
        let intentCategory = readString(stmt, 6)
        let sourceTypeStr = readString(stmt, 7)
        let topicTerms = decodeJSON(readString(stmt, 8))
        let confidence = sqlite3_column_double(stmt, 9)

        var entry = JournalEntry(
            semanticAction: semanticAction,
            appContext: appContext,
            windowContext: windowContext,
            elementContext: elementContext,
            intentCategory: intentCategory,
            sourceType: JournalEntry.SourceType(rawValue: sourceTypeStr) ?? .userAction,
            topicTerms: topicTerms,
            confidence: confidence
        )
        entry.id = id
        entry.timestamp = timestamp
        return entry
    }
}

