import Cocoa

struct GetClipboardTextTool: ToolDefinition {
    let name = "get_clipboard_text"
    let description = "Get the current text content of the clipboard"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if text.isEmpty {
            return "Clipboard is empty (or contains non-text data)."
        }
        let truncated = text.count > 500 ? String(text.prefix(500)) + "... (truncated)" : text
        return "Clipboard contents: \(truncated)"
    }
}

struct SetClipboardTextTool: ToolDefinition {
    let name = "set_clipboard_text"
    let description = "Copy text to the clipboard"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "The text to copy to the clipboard")
        ], required: ["text"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let text = try requiredString("text", from: args)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return "Copied to clipboard."
    }
}

struct GetClipboardImageTool: ToolDefinition {
    let name = "get_clipboard_image"
    let description = "Check if the clipboard contains an image and describe it"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        if let _ = NSPasteboard.general.data(forType: .png) {
            return "Clipboard contains a PNG image."
        } else if let _ = NSPasteboard.general.data(forType: .tiff) {
            return "Clipboard contains a TIFF image."
        }
        return "No image in clipboard."
    }
}
