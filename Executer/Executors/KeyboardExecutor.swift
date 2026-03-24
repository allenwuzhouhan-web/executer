import Cocoa
import CoreGraphics

// MARK: - Key Code Mapping

/// Maps human-readable key names to CGKeyCode values.
private let keyCodeMap: [String: CGKeyCode] = [
    // Letters
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
    "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
    "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
    "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
    "n": 0x2D, "m": 0x2E,
    // Numbers
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16,
    "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
    // Special keys
    "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
    "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
    "forwarddelete": 0x75,
    // Modifiers (for standalone press)
    "command": 0x37, "cmd": 0x37, "shift": 0x38, "option": 0x3A,
    "alt": 0x3A, "control": 0x3B, "ctrl": 0x3B,
    "capslock": 0x39, "fn": 0x3F,
    // Arrows
    "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
    // Function keys
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60,
    "f6": 0x61, "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D,
    "f11": 0x67, "f12": 0x6F,
    // Punctuation
    "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E,
    "\\": 0x2A, ";": 0x29, "'": 0x27, ",": 0x2B,
    ".": 0x2F, "/": 0x2C, "`": 0x32,
    // Navigation
    "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
]

/// Characters that require Shift to type.
private let shiftCharMap: [Character: String] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
    "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
    "<": ",", ">": ".", "?": "/", "~": "`",
]

/// Convert modifier name to CGEventFlags.
private func modifierFlag(for name: String) -> CGEventFlags? {
    switch name.lowercased() {
    case "command", "cmd": return .maskCommand
    case "shift": return .maskShift
    case "option", "alt": return .maskAlternate
    case "control", "ctrl": return .maskControl
    case "fn": return .maskSecondaryFn
    default: return nil
    }
}

// MARK: - Type Text

struct TypeTextTool: ToolDefinition {
    let name = "type_text"
    let description = "Type text at the current cursor position using virtual keyboard input"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "The text to type"),
        ], required: ["text"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let text = try requiredString("text", from: args)

        let source = CGEventSource(stateID: .hidSystemState)

        for char in text {
            try await typeCharacter(char, source: source)
            try await Task.sleep(nanoseconds: 30_000_000) // 30ms between characters
        }

        return "Typed \(text.count) characters."
    }

    private func typeCharacter(_ char: Character, source: CGEventSource?) async throws {
        let str = String(char)
        let lower = str.lowercased()

        var keyCode: CGKeyCode
        var needsShift = false

        if char.isUppercase, let code = keyCodeMap[lower] {
            keyCode = code
            needsShift = true
        } else if let code = keyCodeMap[lower] {
            keyCode = code
        } else if let base = shiftCharMap[char], let code = keyCodeMap[base] {
            keyCode = code
            needsShift = true
        } else if str == " " {
            keyCode = 0x31 // space
        } else {
            // Fallback: use CGEvent's unicode input
            let unicodeChars = Array(str.utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: unicodeChars.count, unicodeString: unicodeChars)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            return
        }

        // Key down
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            if needsShift { down.flags = .maskShift }
            down.post(tap: .cghidEventTap)
        }
        // Key up
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            if needsShift { up.flags = .maskShift }
            up.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Press Key

struct PressKeyTool: ToolDefinition {
    let name = "press_key"
    let description = "Press a single key, optionally with modifier keys (command, shift, option, control)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "key": JSONSchema.string(description: "Key name: 'enter', 'tab', 'escape', 'space', 'delete', 'up', 'down', 'left', 'right', 'f1'-'f12', or any letter/number"),
            "modifiers": JSONSchema.array(items: JSONSchema.string(description: "Modifier"), description: "Optional modifiers: 'command', 'shift', 'option', 'control'"),
        ], required: ["key"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let key = try requiredString("key", from: args).lowercased()
        let modifierNames = (args["modifiers"] as? [String]) ?? []

        guard let keyCode = keyCodeMap[key] else {
            return "Unknown key: '\(key)'. Use key names like 'enter', 'tab', 'escape', 'a', '1', 'f5', etc."
        }

        var flags = CGEventFlags()
        for mod in modifierNames {
            if let flag = modifierFlag(for: mod) {
                flags.insert(flag)
            }
        }

        let source = CGEventSource(stateID: .hidSystemState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return "Failed to create key event."
        }

        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }

        down.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        up.post(tap: .cghidEventTap)

        let modStr = modifierNames.isEmpty ? "" : modifierNames.joined(separator: "+") + "+"
        return "Pressed \(modStr)\(key)."
    }
}

// MARK: - Hotkey

struct HotkeyTool: ToolDefinition {
    let name = "hotkey"
    let description = "Press a keyboard shortcut (e.g., 'cmd+c', 'cmd+shift+s', 'ctrl+alt+delete')"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "combo": JSONSchema.string(description: "Key combination like 'cmd+c', 'cmd+shift+s', 'ctrl+z'"),
        ], required: ["combo"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let combo = try requiredString("combo", from: args).lowercased()

        let parts = combo.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return "Invalid combo." }

        let key = parts.last!
        let modifierNames = Array(parts.dropLast())

        guard let keyCode = keyCodeMap[key] else {
            return "Unknown key '\(key)' in combo '\(combo)'."
        }

        var flags = CGEventFlags()
        for mod in modifierNames {
            if let flag = modifierFlag(for: mod) {
                flags.insert(flag)
            }
        }

        let source = CGEventSource(stateID: .hidSystemState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return "Failed to create hotkey event."
        }

        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }

        down.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 10_000_000)
        up.post(tap: .cghidEventTap)

        return "Pressed \(combo)."
    }
}

// MARK: - Select All

struct SelectAllTextTool: ToolDefinition {
    let name = "select_all_text"
    let description = "Select all text in the currently focused field (Cmd+A)"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        return try await HotkeyTool().execute(arguments: "{\"combo\": \"cmd+a\"}")
    }
}
