import Foundation

// MARK: - Core Protocols

/// Source of user action observations.
///
/// Conforming types (e.g. `AppObserver`) watch for user interactions
/// and emit them through the `onAction` callback.
protocol ObservationSource: AnyObject {
    /// Called each time a user action is detected.
    var onAction: ((UserAction) -> Void)? { get set }

    /// Begin observing user actions.
    func start()

    /// Stop observing user actions.
    func stop()
}

/// Extracts recurring patterns from a sequence of user actions.
///
/// Conforming types (e.g. `PatternLearner`) analyze raw action history
/// and return workflow patterns that appear frequently.
protocol PatternExtractor {
    /// Analyze `actions` against `existingPatterns` and return any newly
    /// discovered or updated patterns for the given application.
    func extractPatterns(from actions: [UserAction], existingPatterns: [WorkflowPattern], appName: String) -> [WorkflowPattern]
}

/// Provides formatted learning context for LLM prompt injection.
///
/// The returned strings are inserted into system prompts so the model
/// can tailor its behaviour to what it has learned about the user.
protocol LearningContextProviding {
    /// Return a prompt section summarising learned patterns for `appName`.
    func promptSection(forApp appName: String) -> String

    /// Return a prompt section for whichever application is currently frontmost.
    func promptSectionForFrontmostApp() -> String
}

/// Reads UI state from running applications.
///
/// Conforming types (e.g. `ScreenReader`) use the Accessibility API
/// to inspect on-screen elements.
protocol UIStateReader {
    /// Snapshot the frontmost application's UI state.
    static func readFrontmostApp() -> AppSnapshot?

    /// Collect all visible text elements for the process with `pid`.
    static func readVisibleText(pid: pid_t) -> [String]

    /// Return a short human-readable summary of the frontmost app's state.
    static func summarizeFrontmostApp() -> String?
}

/// Stores and retrieves learning data (observations and patterns).
///
/// All mutating operations are async to allow for database or disk I/O.
protocol LearningStore {
    /// Persist a single observation.
    func insertObservation(_ action: UserAction) async

    /// Persist multiple observations in a batch.
    func insertObservations(_ actions: [UserAction]) async

    /// Fetch the most recent observations for `appName`, up to `limit`.
    func recentObservations(forApp appName: String, limit: Int) async -> [UserAction]

    /// Persist a newly discovered workflow pattern.
    func insertPattern(_ pattern: WorkflowPattern) async

    /// Update an existing pattern's frequency count and last-seen date.
    func updatePatternFrequency(id: String, frequency: Int, lastSeen: Date) async

    /// Return the highest-frequency patterns for `appName`, up to `limit`.
    func topPatterns(forApp appName: String, limit: Int) async -> [WorkflowPattern]

    /// Return every distinct application name that has recorded observations.
    func allAppNames() async -> [String]

    /// Return the total number of observations recorded for `appName`.
    func totalObservationCount(forApp appName: String) async -> Int

    /// Delete observations older than `date` to keep the store lean.
    func pruneObservations(olderThan date: Date) async
}

/// Manages the overall learning lifecycle.
///
/// The orchestrator wires together observation, pattern extraction,
/// storage, and context generation.
protocol LearningOrchestrator {
    /// Begin the learning pipeline (observation + periodic extraction).
    func start()

    /// Halt the learning pipeline.
    func stop()

    /// Toggle learning on or off at runtime.
    var isEnabled: Bool { get set }
}
