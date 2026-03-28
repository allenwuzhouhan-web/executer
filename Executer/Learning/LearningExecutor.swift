import Foundation
import AppKit

/// Tool that reads the full UI tree of the frontmost app via Accessibility APIs.
/// No screen recording needed — uses AXUIElement to traverse elements.
struct ReadScreenTool: ToolDefinition {
    let name = "read_screen"
    let description = "Read the entire UI of the frontmost application — all text, buttons, menus, fields, and their positions. Uses Accessibility APIs, no screen recording needed. Returns a structured tree of UI elements."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "max_elements": JSONSchema.integer(description: "Maximum elements to return (default 80, max 200)", minimum: 10, maximum: 200),
        ])
    }

    func execute(arguments: String) async throws -> String {
        guard let snapshot = ScreenReader.readFrontmostApp() else {
            return "Could not read the frontmost app. Make sure Accessibility permission is granted."
        }
        return snapshot.summary()
    }
}

/// Tool that reads the visible text from the frontmost app (lightweight).
struct ReadAppTextTool: ToolDefinition {
    let name = "read_app_text"
    let description = "Read all visible text from the frontmost application. Faster than read_screen — returns just the text content without positions or element types."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "No frontmost application."
        }
        let texts = ScreenReader.readVisibleText(pid: app.processIdentifier)
        if texts.isEmpty {
            return "No readable text found in \(app.localizedName ?? "the app")."
        }
        return "Text from \(app.localizedName ?? "app"):\n\(texts.joined(separator: "\n"))"
    }
}

/// Tool that returns the user's learned workflow patterns for an app.
struct GetLearnedPatternsTool: ToolDefinition {
    let name = "get_learned_patterns"
    let description = "Get the user's learned workflow patterns for a specific app. Shows how the user typically uses the app — what they click, what they type, in what order. Use this to replicate the user's workflow."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "The app name (e.g. 'Keynote', 'Safari', 'Microsoft PowerPoint')"),
        ], required: ["app_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = try requiredString("app_name", from: args)

        let patterns = LearningManager.shared.promptSection(forApp: appName)
        if patterns.isEmpty {
            return "No learned patterns for \(appName) yet. The user hasn't used this app enough while Executer was running."
        }
        return patterns
    }
}

/// Tool that lists all apps with learned patterns.
struct ListLearnedAppsTool: ToolDefinition {
    let name = "list_learned_apps"
    let description = "List all apps that Executer has learned patterns from, with pattern and action counts."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        return LearningManager.shared.overallSummary()
    }
}
