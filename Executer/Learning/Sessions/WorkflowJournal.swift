import Foundation

// MARK: - Workflow Journal

/// A structured record of a single logical task the user performed.
/// Opened when TaskBoundaryDetector fires a boundary, closed on the next boundary.
///
/// This is the missing middle layer between raw observations (too granular)
/// and work sessions (too coarse). When the user says "do that again,"
/// the journal provides a clean, ordered account of what "that" was.
struct WorkflowJournal: Codable, Identifiable, Sendable {
    var id: UUID
    var taskDescription: String         // Auto-generated from first few entries
    var status: Status
    var entries: [JournalEntry]
    var apps: [String]                  // Ordered list of apps used in this task
    var topicTerms: [String]            // Accumulated topic keywords
    var startTime: Date
    var endTime: Date
    var boundaryId: UUID?               // ID of the TaskBoundary that opened this journal
    var closingBoundaryId: UUID?        // ID of the TaskBoundary that closed it

    enum Status: String, Codable, Sendable {
        case active                      // Currently being recorded
        case closed                      // Task ended, journal finalized
        case archived                    // Older than 30 days, moved to archive
    }

    init(boundaryId: UUID? = nil, firstApp: String = "Unknown") {
        self.id = UUID()
        self.taskDescription = ""
        self.status = .active
        self.entries = []
        self.apps = [firstApp]
        self.topicTerms = []
        self.startTime = Date()
        self.endTime = Date()
        self.boundaryId = boundaryId
        self.closingBoundaryId = nil
    }

    /// Append an entry to this journal.
    mutating func append(_ entry: JournalEntry) {
        entries.append(entry)
        endTime = entry.timestamp

        if !apps.contains(entry.appContext) {
            apps.append(entry.appContext)
        }

        // Auto-generate task description from first meaningful entry
        if taskDescription.isEmpty && !entry.semanticAction.isEmpty {
            taskDescription = entry.semanticAction
        }

        // Accumulate topic terms (dedup, cap at 20)
        for term in entry.topicTerms where !topicTerms.contains(term) {
            if topicTerms.count < 20 {
                topicTerms.append(term)
            }
        }
    }

    /// Close the journal.
    mutating func close(boundaryId: UUID?) {
        status = .closed
        endTime = Date()
        closingBoundaryId = boundaryId
    }

    /// Archive the journal.
    mutating func archive() {
        status = .archived
    }

    /// Duration of the task.
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// Formatted duration.
    var durationFormatted: String {
        let seconds = Int(duration)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Brief summary for display.
    var summary: String {
        let desc = taskDescription.isEmpty ? "Untitled task" : taskDescription
        return "\(desc) (\(durationFormatted), \(entries.count) actions, \(apps.joined(separator: " → ")))"
    }
}

// MARK: - Journal Entry

/// A single semantically meaningful action within a workflow journal.
/// Captures WHAT happened, WHERE, WHEN, and inferred WHY.
///
/// Unlike raw UserAction (mechanical: "clicked AXButton titled Submit"),
/// JournalEntry captures meaning: "Submitted the search form in Safari".
struct JournalEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var timestamp: Date

    // WHAT: semantic action (verb + object)
    let semanticAction: String          // "Submitted search form", "Opened document", "Copied table data"

    // WHERE: app + window + element context
    let appContext: String              // "Safari", "Excel", "Finder"
    let windowContext: String           // "Google Search", "Q1 Revenue.xlsx"
    let elementContext: String          // "search text field", "cell B12", "Submit button"

    // WHY: inferred intent category
    let intentCategory: String          // "researching", "creating", "communicating", "organizing"

    // Source: what observation type produced this entry
    let sourceType: SourceType

    // Topic terms extracted from this entry (for drift detection and search)
    let topicTerms: [String]

    // Confidence in the semantic extraction
    let confidence: Double

    enum SourceType: String, Codable, Sendable {
        case userAction                  // From AX event
        case fileEvent                   // From file system monitor
        case clipboardFlow               // From clipboard observer
        case screenSample                // From periodic screen read
        case systemEvent                 // From system event bus
    }

    init(
        semanticAction: String,
        appContext: String,
        windowContext: String = "",
        elementContext: String = "",
        intentCategory: String = "unknown",
        sourceType: SourceType,
        topicTerms: [String] = [],
        confidence: Double = 0.5
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.semanticAction = semanticAction
        self.appContext = appContext
        self.windowContext = windowContext
        self.elementContext = elementContext
        self.intentCategory = intentCategory
        self.sourceType = sourceType
        self.topicTerms = topicTerms
        self.confidence = confidence
    }
}
