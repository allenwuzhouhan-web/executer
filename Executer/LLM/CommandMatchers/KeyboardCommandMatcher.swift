import Foundation

extension LocalCommandRouter {

    func tryKeyboardCommand(_ input: String) async -> String? {
        // "type [text]"
        if input.hasPrefix("type ") {
            let text = String(input.dropFirst("type ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return try? await TypeTextTool().execute(arguments: "{\"text\": \"\(escapeJSON(text))\"}")
            }
        }

        // Press specific keys
        let keyPresses: [String: String] = [
            "press enter": "enter", "hit enter": "enter",
            "press tab": "tab", "hit tab": "tab",
            "press escape": "escape", "hit escape": "escape",
            "press space": "space", "hit space": "space",
            "press delete": "delete", "hit delete": "delete",
            "press backspace": "backspace", "hit backspace": "backspace",
        ]
        if let key = keyPresses[input] {
            return try? await PressKeyTool().execute(arguments: "{\"key\": \"\(key)\"}")
        }

        // Common hotkeys
        let hotkeys: [String: String] = [
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
        if let combo = hotkeys[input] {
            return try? await HotkeyTool().execute(arguments: "{\"combo\": \"\(combo)\"}")
        }

        return nil
    }
}
