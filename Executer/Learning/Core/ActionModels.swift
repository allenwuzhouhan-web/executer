import Foundation

// MARK: - User Action

/// Represents a single user action observed via Accessibility APIs.
struct UserAction: Codable, Hashable, Sendable {
    let type: ActionType
    let appName: String
    let elementRole: String
    let elementTitle: String
    let elementValue: String
    let timestamp: Date

    enum ActionType: String, Codable, Hashable, Sendable {
        case focus       // User focused on an element
        case click       // User clicked a button/menu item
        case textEdit    // User typed or changed text
        case windowOpen  // New window appeared
        case menuSelect  // Menu item selected
        case tabSwitch   // Tab changed
    }

    /// Action signature for pattern matching (ignores variable content)
    var signature: String {
        "\(type.rawValue):\(elementRole):\(elementTitle)"
    }
}

// MARK: - Workflow Pattern

/// A sequence of actions that forms a recurring workflow pattern.
struct WorkflowPattern: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let appName: String
    let name: String
    let actions: [PatternAction]
    var frequency: Int
    let firstSeen: Date
    var lastSeen: Date

    struct PatternAction: Codable, Hashable, Sendable {
        let type: UserAction.ActionType
        let elementRole: String
        let elementTitle: String
        let elementValue: String
    }

    static func == (lhs: WorkflowPattern, rhs: WorkflowPattern) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Legacy Profile (for JSON migration only)

/// Per-app collection of observed actions and extracted patterns.
/// Used during migration from JSON files to SQLite. After migration,
/// data lives in LearningDatabase tables instead.
struct AppLearningProfile: Codable {
    let appName: String
    var recentActions: [UserAction]
    var patterns: [WorkflowPattern]
    var totalActionsObserved: Int
    var lastUpdated: Date

    /// Returns a prompt-friendly summary of learned patterns for this app.
    func promptSummary() -> String {
        guard !patterns.isEmpty else { return "" }

        var lines = ["## Learned Patterns for \(appName) (from observing the user):"]
        let topPatterns = patterns.sorted { $0.frequency > $1.frequency }.prefix(LearningConstants.maxPatternsInPrompt)

        for pattern in topPatterns {
            lines.append("### \(pattern.name) (observed \(pattern.frequency)x)")
            for (i, action) in pattern.actions.enumerated() {
                var step = "  \(i + 1). \(action.type.rawValue)"
                if !action.elementTitle.isEmpty { step += " → \"\(action.elementTitle)\"" }
                if !action.elementRole.isEmpty { step += " [\(action.elementRole)]" }
                if !action.elementValue.isEmpty { step += " = \"\(action.elementValue.prefix(80))\"" }
                lines.append(step)
            }
        }

        return lines.joined(separator: "\n")
    }
}
