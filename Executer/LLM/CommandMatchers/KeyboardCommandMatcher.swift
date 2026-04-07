import Foundation

extension LocalCommandRouter {

    // Friendly hotkey aliases — common names people use
    private static let hotkeyAliases: [String: String] = [
        "copy": "cmd+c", "paste": "cmd+v", "cut": "cmd+x",
        "undo": "cmd+z", "redo": "cmd+shift+z",
        "save": "cmd+s", "save file": "cmd+s",
        "select all": "cmd+a",
        "find": "cmd+f", "find in page": "cmd+f",
        "new tab": "cmd+t", "close tab": "cmd+w",
        "new window": "cmd+n", "close window": "cmd+w",
        "refresh": "cmd+r", "reload": "cmd+r",
        "zoom in": "cmd+=", "zoom out": "cmd+-",
        "print": "cmd+p",
        "quit app": "cmd+q",
        "force quit": "cmd+option+escape",
        "spotlight": "cmd+space",
        "switch app": "cmd+tab",
        "minimize": "cmd+m",
        "full screen": "cmd+ctrl+f",
    ]

    func tryKeyboardCommand(_ input: String) async -> String? {
        // "type [text]"
        if input.hasPrefix("type ") {
            let text = String(input.dropFirst("type ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return try? await TypeTextTool().execute(arguments: "{\"text\": \"\(escapeJSON(text))\"}")
            }
        }

        // Friendly hotkey aliases: "copy", "paste", "undo", etc.
        if let combo = Self.hotkeyAliases[input] {
            return try? await HotkeyTool().execute(arguments: "{\"combo\": \"\(combo)\"}")
        }

        // Dynamic hotkey parsing: "cmd+c", "ctrl+shift+a", "command+option+escape"
        // Matches any combo with modifier+key pattern
        if let combo = Self.parseHotkeyCombo(input) {
            return try? await HotkeyTool().execute(arguments: "{\"combo\": \"\(combo)\"}")
        }

        // "press [key]" / "hit [key]" — dynamic: accept any key name
        for prefix in ["press ", "hit "] {
            if input.hasPrefix(prefix) {
                let rawKey = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let key = Self.resolveKeyName(rawKey) {
                    return try? await PressKeyTool().execute(arguments: "{\"key\": \"\(key)\"}")
                }
                // Could be a hotkey combo: "press cmd+c"
                if let combo = Self.parseHotkeyCombo(rawKey) {
                    return try? await HotkeyTool().execute(arguments: "{\"combo\": \"\(combo)\"}")
                }
            }
        }

        return nil
    }

    // MARK: - Dynamic Key Resolution

    /// Resolves any key name to the format PressKeyTool expects.
    /// Handles: "enter", "return", "f5", "arrow up", "page down", "home", "end", etc.
    private static func resolveKeyName(_ raw: String) -> String? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return nil }

        // Direct key names the tool already understands
        let directKeys: Set<String> = [
            "enter", "return", "tab", "escape", "space",
            "delete", "backspace", "forwarddelete",
            "home", "end", "pageup", "pagedown",
            "up", "down", "left", "right",
            "capslock", "shift", "control", "option", "command",
        ]
        if directKeys.contains(lower) { return lower }

        // Key name aliases
        let keyAliases: [String: String] = [
            // Arrow keys
            "arrow up": "up", "arrow down": "down",
            "arrow left": "left", "arrow right": "right",
            "up arrow": "up", "down arrow": "down",
            "left arrow": "left", "right arrow": "right",
            // Page navigation
            "page up": "pageup", "page down": "pagedown",
            "forward delete": "forwarddelete",
            // Aliases
            "esc": "escape", "ret": "return", "del": "delete",
            "caps lock": "capslock", "caps": "capslock",
            "ctrl": "control", "cmd": "command", "opt": "option", "alt": "option",
        ]
        if let resolved = keyAliases[lower] { return resolved }

        // Function keys: f1-f20
        if lower.hasPrefix("f"), let num = Int(lower.dropFirst(1)), num >= 1 && num <= 20 {
            return lower
        }

        return nil
    }

    // MARK: - Dynamic Hotkey Combo Parsing

    /// Parses any hotkey combo string into the normalized format: "mod1+mod2+key"
    /// Accepts: "cmd+c", "ctrl+shift+a", "command+option+escape", "⌘c", "⌘⇧a"
    private static func parseHotkeyCombo(_ raw: String) -> String? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)

        // Must contain a separator (+, -, or space between modifier and key)
        // Try "+" first (most common), then "-"
        let separator: Character
        if lower.contains("+") {
            separator = "+"
        } else if lower.contains("-") && lower.count > 3 {
            separator = "-"
        } else {
            return nil
        }

        let parts = lower.split(separator: separator).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }

        let modifierMap: [String: String] = [
            "cmd": "cmd", "command": "cmd", "⌘": "cmd",
            "ctrl": "ctrl", "control": "ctrl", "⌃": "ctrl",
            "opt": "option", "option": "option", "alt": "option", "⌥": "option",
            "shift": "shift", "⇧": "shift",
            "fn": "fn",
        ]

        var modifiers: [String] = []
        var key: String?

        for part in parts {
            if let mod = modifierMap[part] {
                modifiers.append(mod)
            } else {
                // Last non-modifier part is the key
                key = part
            }
        }

        guard !modifiers.isEmpty, let finalKey = key, !finalKey.isEmpty else { return nil }

        // Normalize modifier order: cmd, ctrl, option, shift, fn
        let order = ["cmd", "ctrl", "option", "shift", "fn"]
        modifiers.sort { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }

        return (modifiers + [finalKey]).joined(separator: "+")
    }
}
