import Foundation

// MARK: - Task Boundary

/// Represents a detected boundary between two logical tasks.
/// Emitted by TaskBoundaryDetector when it determines the user has switched
/// from one task to another. This triggers journal open/close events in Phase 3.
struct TaskBoundary: Sendable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let confidence: Double          // 0.0–1.0: how confident the detector is this is a real boundary
    let trigger: TriggerEvent       // What observation triggered this boundary
    let signals: [SignalContribution]  // Breakdown of which signals contributed

    init(kind: Kind, confidence: Double, trigger: TriggerEvent, signals: [SignalContribution]) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.confidence = confidence
        self.trigger = trigger
        self.signals = signals
    }

    /// Type of boundary.
    enum Kind: String, Sendable {
        /// Hard boundary: strong signals like new document, explicit app quit+relaunch, etc.
        case hard
        /// Soft boundary: gradual topic drift detected without a single decisive event.
        case soft
        /// Temporal boundary: inactivity gap exceeded threshold.
        case temporal
    }

    /// What triggered the boundary detection.
    enum TriggerEvent: Sendable {
        case appSwitch(from: String, to: String)
        case documentChange(app: String, windowTitle: String)
        case topicDrift(distance: Double)
        case temporalGap(seconds: TimeInterval)
        case systemEvent(kind: String)  // screenLocked, screenUnlocked, etc.
    }

    /// Contribution of each signal to the boundary decision.
    struct SignalContribution: Sendable {
        let signal: BoundarySignal
        let weight: Double       // How much this signal contributed (0–1)
        let rawValue: Double     // The raw signal value before weighting
    }
}

// MARK: - Boundary Signals

/// The individual signals that TaskBoundaryDetector fuses to detect boundaries.
enum BoundarySignal: String, CaseIterable, Sendable {
    /// Rapid app switching: high velocity = exploration (not a boundary),
    /// single decisive switch after sustained activity = likely boundary.
    case appSwitchPattern

    /// New document/window events: Cmd+N, new window title, file open dialog.
    case documentChange

    /// Topic drift: embedding distance from running centroid exceeds threshold.
    case topicDrift

    /// Temporal gap: no events for N seconds.
    case temporalGap

    /// System events: screen lock/unlock, app quit.
    case systemEvent
}

// MARK: - Task Context

/// Running context for the current task. Maintained by TaskBoundaryDetector
/// to track state needed for boundary detection.
struct TaskContext: Sendable {
    let id: UUID
    let startTime: Date
    var lastEventTime: Date
    var primaryApp: String              // The app used most during this task
    var apps: [String]                  // Ordered list of apps touched
    var appSwitchCount: Int             // Number of app switches within this task
    var topicCentroid: [Double]?        // Running centroid embedding of task topics
    var topicTerms: Set<String>         // Accumulated topic terms
    var observationCount: Int           // How many events have been assigned to this task
    var lastWindowTitle: String?        // Last window title seen (for document change detection)

    init(firstApp: String, startTime: Date = Date()) {
        self.id = UUID()
        self.startTime = startTime
        self.lastEventTime = startTime
        self.primaryApp = firstApp
        self.apps = [firstApp]
        self.appSwitchCount = 0
        self.topicCentroid = nil
        self.topicTerms = []
        self.observationCount = 1
        self.lastWindowTitle = nil
    }

    /// Duration of the current task so far.
    var duration: TimeInterval {
        lastEventTime.timeIntervalSince(startTime)
    }

    /// Update the running centroid with a new topic embedding.
    /// Uses exponential moving average so recent topics matter more.
    mutating func updateCentroid(with newVector: [Double], alpha: Double = 0.3) {
        guard var centroid = topicCentroid, centroid.count == newVector.count else {
            topicCentroid = newVector
            return
        }
        // EMA: centroid = alpha * new + (1 - alpha) * old
        for i in centroid.indices {
            centroid[i] = alpha * newVector[i] + (1.0 - alpha) * centroid[i]
        }
        topicCentroid = centroid
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a task boundary is detected. UserInfo contains the TaskBoundary.
    static let taskBoundaryDetected = Notification.Name("com.executer.taskBoundaryDetected")
}
