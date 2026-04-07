import Foundation

// MARK: - Pattern Classification

enum PatternType: String, Codable, Sendable, CaseIterable {
    case appUsage       // Which apps, how often, when
    case workflow       // Repeated transition sequences
    case routine        // Time-bound habits
    case project        // Co-occurring app/URL/file clusters
    case communication  // Who, where, when
    case preference     // Inferred behavioral fingerprints
}

enum BeliefClassification: String, Codable, Sendable {
    case belief      // confidence >= 0.7 — actionable, can be surfaced
    case hypothesis  // 0.3 <= confidence < 0.7 — stored, never surfaced
    case noise       // confidence < 0.3 — eligible for garbage collection

    static func from(confidence: Double) -> BeliefClassification {
        if confidence >= 0.7 { return .belief }
        if confidence >= 0.3 { return .hypothesis }
        return .noise
    }
}

// MARK: - Interaction Mode

/// Distinguishes active choices from passive drift (Principle 4).
enum InteractionMode: String, Codable, Sendable {
    case active    // Significant keystrokes + clicks — full weight (1.0)
    case browsing  // Mostly scrolling, some clicks — medium weight (0.5)
    case passive   // Minimal interaction, app just open — low weight (0.1)
    case idle      // Zero interaction > 2 min — no weight (0.0)

    /// Observation weight per Principle 4: active choices get full weight,
    /// passive drift gets minimal weight.
    var observationWeight: Double {
        switch self {
        case .active:   return 1.0
        case .browsing: return 0.5
        case .passive:  return 0.1
        case .idle:     return 0.0
        }
    }

    /// Classify from raw interaction counts within a 30-second window.
    static func classify(keystrokes: Int, clicks: Int, scrollDistance: CGFloat) -> InteractionMode {
        let totalInteractions = keystrokes + clicks
        if totalInteractions == 0 && scrollDistance < 10 { return .idle }
        if keystrokes >= 5 || (keystrokes >= 2 && clicks >= 2) { return .active }
        if clicks >= 3 || scrollDistance > 200 { return .browsing }
        if totalInteractions > 0 || scrollDistance > 10 { return .passive }
        return .idle
    }
}

// MARK: - File Event Type

enum ObservedFileEventType: String, Codable, Sendable {
    case created, modified, deleted, renamed
}

// MARK: - Observer Source

enum ObserverType: String, Codable, Sendable {
    case app, url, activity, transition, file
}
