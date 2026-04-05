import Foundation

/// Manages the lifecycle of workflow journals.
///
/// - Opens a new journal when TaskBoundaryDetector fires a boundary
/// - Appends entries from ObservationStream events to the active journal
/// - Closes the active journal when the next boundary fires
/// - Persists journals to JournalStore (SQLite)
///
/// One active journal at a time. Entries are buffered in memory and
/// flushed to SQLite periodically or on journal close.
actor JournalManager {
    static let shared = JournalManager()

    // MARK: - State

    /// The currently active journal (being recorded to).
    private(set) var activeJournal: WorkflowJournal?

    /// Buffer of entries not yet flushed to SQLite.
    private var entryBuffer: [JournalEntry] = []

    /// Maximum entries to buffer before flushing (low to minimize crash data loss).
    private let flushThreshold = 5

    /// Total journals created this session.
    private(set) var journalsCreatedThisSession = 0

    /// Total entries recorded this session.
    private(set) var entriesRecordedThisSession = 0

    // MARK: - Journal Lifecycle

    /// Handle a task boundary event — close the active journal and open a new one.
    /// Opens the new journal BEFORE closing the old one to eliminate the gap
    /// where events could be dropped (activeJournal was nil between close and open).
    func handleBoundary(_ boundary: TaskBoundary) {
        // Create new journal FIRST so activeJournal is never nil
        let newJournal = WorkflowJournal(boundaryId: boundary.id, firstApp: extractApp(from: boundary))

        // Close the old journal
        if var oldJournal = activeJournal {
            flushEntryBuffer(to: &oldJournal)
            oldJournal.close(boundaryId: boundary.id)
            JournalStore.shared.updateJournal(oldJournal)
            print("[JournalManager] Closed journal: \(oldJournal.summary)")

            // Phase 4: Generalize the completed journal into a reusable workflow
            let closedJournal = oldJournal
            Task.detached(priority: .utility) {
                if let workflow = SemanticGeneralizer.generalize(closedJournal) {
                    JournalStore.shared.insertGeneralizedWorkflow(workflow)
                }
            }
        }

        // Activate the new journal (was created before close, so no gap)
        activeJournal = newJournal
        journalsCreatedThisSession += 1
        JournalStore.shared.insertJournal(newJournal)
        print("[JournalManager] Opened journal #\(journalsCreatedThisSession) in \(newJournal.apps.first ?? "Unknown")")
    }

    /// Open a new journal.
    private func openNewJournal(boundaryId: UUID?, triggerApp: String) {
        let journal = WorkflowJournal(boundaryId: boundaryId, firstApp: triggerApp)
        activeJournal = journal
        journalsCreatedThisSession += 1

        // Persist immediately
        JournalStore.shared.insertJournal(journal)
        print("[JournalManager] Opened journal #\(journalsCreatedThisSession) in \(triggerApp)")
    }

    /// Force-open a journal if none is active (e.g., on first launch).
    func ensureActiveJournal(app: String) {
        guard activeJournal == nil else { return }
        openNewJournal(boundaryId: nil, triggerApp: app)
    }

    // MARK: - Entry Recording

    /// Process an ObservationEvent and convert it to a JournalEntry.
    func recordEvent(_ event: ObservationEvent) {
        // Ensure we have an active journal
        if activeJournal == nil, let app = event.appName {
            openNewJournal(boundaryId: nil, triggerApp: app)
        }
        guard activeJournal != nil else { return }

        // Convert event to journal entry
        guard let entry = makeEntry(from: event) else { return }

        // Append to in-memory journal
        activeJournal?.append(entry)
        entryBuffer.append(entry)
        entriesRecordedThisSession += 1

        // Flush if buffer is full
        if entryBuffer.count >= flushThreshold {
            if var journal = activeJournal {
                flushEntryBuffer(to: &journal)
                activeJournal = journal
            }
        }
    }

    // MARK: - Entry Conversion

    /// Convert an ObservationEvent into a JournalEntry.
    /// Returns nil for events that aren't semantically meaningful enough to journal.
    private func makeEntry(from event: ObservationEvent) -> JournalEntry? {
        switch event {
        case .userAction(let action):
            return makeEntryFromUserAction(action)
        case .fileEvent(let fileEvent):
            return JournalEntry(
                semanticAction: "File \(fileEvent.eventType.rawValue) in \(fileEvent.directory)",
                appContext: fileEvent.appName,
                windowContext: fileEvent.directory,
                elementContext: fileEvent.fileExtension,
                intentCategory: "organizing",
                sourceType: .fileEvent,
                topicTerms: [fileEvent.directory, fileEvent.fileExtension],
                confidence: 0.6
            )
        case .clipboardFlow(let flow):
            return JournalEntry(
                semanticAction: "Copied \(flow.contentType.rawValue) from \(flow.sourceApp) to \(flow.destinationApp)",
                appContext: flow.sourceApp,
                windowContext: "",
                elementContext: "\(flow.contentType.rawValue) (\(flow.contentLength) chars)",
                intentCategory: "transferring",
                sourceType: .clipboardFlow,
                topicTerms: [flow.sourceApp, flow.destinationApp],
                confidence: 0.7
            )
        case .screenSample:
            // Screen samples are too frequent for individual entries.
            // They feed into topic drift detection but don't generate entries.
            return nil
        case .systemEvent(let sysEvent):
            return makeEntryFromSystemEvent(sysEvent)
        }
    }

    private func makeEntryFromUserAction(_ action: UserAction) -> JournalEntry? {
        // Skip noisy focus events on generic elements
        if action.type == .focus && action.elementRole == "AXGroup" { return nil }
        if action.type == .focus && action.elementTitle.isEmpty { return nil }

        let semanticAction: String
        let intentCategory: String

        switch action.type {
        case .click:
            semanticAction = "Clicked \(action.elementTitle.isEmpty ? action.elementRole : "'\(action.elementTitle)'")"
            intentCategory = "interacting"
        case .textEdit:
            // Don't record the actual text (privacy) — just that editing occurred
            let target = action.elementTitle.isEmpty ? action.elementRole : action.elementTitle
            semanticAction = "Edited text in \(target)"
            intentCategory = "creating"
        case .menuSelect:
            semanticAction = "Selected menu item '\(action.elementTitle)'"
            intentCategory = "navigating"
        case .windowOpen:
            semanticAction = "Opened window '\(action.elementTitle)'"
            intentCategory = "navigating"
        case .tabSwitch:
            semanticAction = "Switched to tab '\(action.elementTitle)'"
            intentCategory = "navigating"
        case .textSelect:
            let target = action.elementTitle.isEmpty ? action.elementRole : action.elementTitle
            semanticAction = "Selected text in \(target)"
            intentCategory = "reviewing"
        case .focus:
            semanticAction = "Focused on \(action.elementTitle.isEmpty ? action.elementRole : "'\(action.elementTitle)'")"
            intentCategory = "navigating"
        }

        return JournalEntry(
            semanticAction: semanticAction,
            appContext: action.appName,
            windowContext: "",
            elementContext: "\(action.elementRole) \(action.elementTitle)".trimmingCharacters(in: .whitespaces),
            intentCategory: intentCategory,
            sourceType: .userAction,
            topicTerms: [action.appName, action.elementTitle].filter { !$0.isEmpty },
            confidence: action.type == .click || action.type == .menuSelect ? 0.8 : 0.5
        )
    }

    private func makeEntryFromSystemEvent(_ event: SystemObservationEvent) -> JournalEntry? {
        switch event.kind {
        case .appLaunched(let name):
            return JournalEntry(
                semanticAction: "Launched \(name)",
                appContext: name,
                intentCategory: "launching",
                sourceType: .systemEvent,
                topicTerms: [name],
                confidence: 0.9
            )
        case .appQuit(let name):
            return JournalEntry(
                semanticAction: "Quit \(name)",
                appContext: name,
                intentCategory: "closing",
                sourceType: .systemEvent,
                topicTerms: [name],
                confidence: 0.9
            )
        default:
            return nil
        }
    }

    // MARK: - Flushing

    /// Flush buffered entries to SQLite.
    private func flushEntryBuffer(to journal: inout WorkflowJournal) {
        guard !entryBuffer.isEmpty else { return }
        JournalStore.shared.insertEntries(entryBuffer, journalId: journal.id)
        JournalStore.shared.updateJournal(journal)
        entryBuffer.removeAll(keepingCapacity: true)
    }

    /// Flush and close everything (called on app shutdown).
    func shutdown() {
        if var journal = activeJournal {
            flushEntryBuffer(to: &journal)
            journal.close(boundaryId: nil)
            JournalStore.shared.updateJournal(journal)
            activeJournal = nil
            print("[JournalManager] Shutdown — closed active journal")
        }
    }

    // MARK: - Helpers

    private func extractApp(from boundary: TaskBoundary) -> String {
        switch boundary.trigger {
        case .appSwitch(_, let to): return to
        case .documentChange(let app, _): return app
        default: return "Unknown"
        }
    }

    // MARK: - Status

    func statusDescription() -> String {
        var lines = ["JournalManager:"]
        if let journal = activeJournal {
            lines.append("  Active: \(journal.summary)")
        } else {
            lines.append("  No active journal")
        }
        lines.append("  Session: \(journalsCreatedThisSession) journals, \(entriesRecordedThisSession) entries")
        lines.append("  Stored: \(JournalStore.shared.journalCount()) total, \(JournalStore.shared.journalCount(status: .active)) active, \(JournalStore.shared.journalCount(status: .closed)) closed, \(JournalStore.shared.journalCount(status: .archived)) archived")
        return lines.joined(separator: "\n")
    }
}
