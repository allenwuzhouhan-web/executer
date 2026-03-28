import Foundation

/// Represents a single user action observed via Accessibility APIs.
struct UserAction: Codable {
    let type: ActionType
    let appName: String
    let elementRole: String
    let elementTitle: String
    let elementValue: String
    let timestamp: Date

    enum ActionType: String, Codable {
        case focus       // User focused on an element
        case click       // User clicked a button/menu item
        case textEdit    // User typed or changed text
        case windowOpen  // New window appeared
        case menuSelect  // Menu item selected
        case tabSwitch   // Tab changed
    }
}

/// A sequence of actions that forms a workflow pattern.
struct WorkflowPattern: Codable, Identifiable {
    let id: UUID
    let appName: String
    let name: String            // Auto-generated: "Create New Slide in Keynote"
    let actions: [PatternAction]
    var frequency: Int          // How many times this pattern was observed
    let firstSeen: Date
    var lastSeen: Date

    struct PatternAction: Codable {
        let type: UserAction.ActionType
        let elementRole: String
        let elementTitle: String
        let elementValue: String  // Template: actual value or "" for variable content
    }
}

/// Per-app collection of observed actions and extracted patterns.
struct AppLearningProfile: Codable {
    let appName: String
    var recentActions: [UserAction]       // Rolling buffer, max 500
    var patterns: [WorkflowPattern]       // Extracted recurring workflows, max 20
    var totalActionsObserved: Int
    var lastUpdated: Date

    /// Returns a prompt-friendly summary of learned patterns for this app.
    func promptSummary() -> String {
        guard !patterns.isEmpty else { return "" }

        var lines = ["## Learned Patterns for \(appName) (from observing the user):"]
        let topPatterns = patterns.sorted { $0.frequency > $1.frequency }.prefix(10)

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
