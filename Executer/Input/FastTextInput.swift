import Foundation
import AppKit
import CoreGraphics

/// Fast text entry methods. Clipboard-paste is ~50ms constant time vs. 30ms * N for typing.
enum FastTextInput {

    /// Paste text via clipboard (fastest: ~50ms for any length).
    /// Saves and restores the original clipboard atomically.
    static func pasteText(_ text: String) async throws -> String {
        let pasteboard = NSPasteboard.general

        // Save original clipboard contents (all types)
        let savedItems = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData[type] = data
                }
            }
            return itemData
        }

        defer {
            // Restore original clipboard
            pasteboard.clearContents()
            if let savedItems = savedItems {
                for itemData in savedItems {
                    let item = NSPasteboardItem()
                    for (type, data) in itemData {
                        item.setData(data, forType: type)
                    }
                    pasteboard.writeObjects([item])
                }
            }
        }

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 0x09 // 'v'

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return "Failed to create paste event."
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        keyUp.post(tap: .cghidEventTap)

        // Wait for paste to complete
        try await Task.sleep(nanoseconds: 40_000_000) // 40ms

        return "Pasted \(text.count) characters."
    }

    /// Type text character-by-character (existing behavior, for apps that don't accept paste).
    static func typeText(_ text: String, charDelayMs: Int = 30) async throws -> String {
        // Delegate to existing KeyboardExecutor typing logic
        let args = "{\"text\": \(escapeJSON(text))}"
        return try await TypeTextTool().execute(arguments: args)
    }

    /// Smart entry: try paste first, fall back to typing if text is short.
    static func smartEntry(_ text: String) async throws -> String {
        // For very short text (1-2 chars), typing is fine
        if text.count <= 2 {
            return try await typeText(text)
        }
        // For everything else, paste is faster
        return try await pasteText(text)
    }

    private static func escapeJSON(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

// MARK: - Paste Text Tool

struct PasteTextTool: ToolDefinition {
    let name = "paste_text"
    let description = "Paste text into the focused field via clipboard (much faster than typing). Use this for entering text longer than 2 characters."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "The text to paste"),
        ], required: ["text"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let text = try requiredString("text", from: args)
        return try await FastTextInput.pasteText(text)
    }
}
