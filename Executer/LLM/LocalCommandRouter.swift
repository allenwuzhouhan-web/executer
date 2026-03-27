import Foundation
import CoreGraphics
import AppKit

/// Routes simple, unambiguous commands directly to executors without calling the LLM API.
/// This makes common actions (volume, brightness, app launch, music, web, etc.) feel instant.
///
/// Matcher methods are in separate files under CommandMatchers/:
/// - AppCommandMatcher.swift — open/quit/switch/hide app
/// - WebCommandMatcher.swift — URL navigation, search, shortcuts
/// - MusicCommandMatcher.swift — play/pause/next/previous/shuffle
/// - TimerCommandMatcher.swift — timers, reminders, notes
/// - CursorCommandMatcher.swift — click, scroll, move cursor
/// - KeyboardCommandMatcher.swift — type, press key, hotkeys
/// - DictionaryCommandMatcher.swift — define, synonyms, spell check
/// - CommandParsingHelpers.swift — shared utilities
class LocalCommandRouter {
    static let shared = LocalCommandRouter()
    private init() {}

    /// Returns a result string if the command was handled locally, or nil to fall through to the LLM.
    func tryLocalExecution(_ command: String) async -> String? {
        let input = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = Set(input.split(separator: " ").map { String($0) })

        // --- Prefix/pattern-based matching ---

        if let result = await tryAppCommand(input) { return result }
        if let result = await tryWebNavigation(input) { return result }
        if let result = await trySearchCommand(input) { return result }
        if let result = await tryMusicCommand(input, words: words) { return result }
        if let result = await tryTimerReminder(input) { return result }
        if let result = await tryCursorCommand(input, words: words) { return result }
        if let result = await tryKeyboardCommand(input) { return result }
        if let result = await tryDictionaryCommand(input) { return result }
        if let result = await tryTranslation(input) { return result }
        if let result = await tryMessagingCommand(command) { return result }

        // --- Keyword-based matching ---

        // Volume
        if matches(words, required: ["volume", "up"]) || input == "louder" ||
           matches(words, required: ["turn", "up", "volume"]) || matches(words, required: ["crank", "up", "volume"]) ||
           matches(words, required: ["increase", "volume"]) {
            return await adjustVolume(delta: 10)
        }
        if matches(words, required: ["volume", "down"]) || input == "quieter" || input == "softer" ||
           matches(words, required: ["turn", "down", "volume"]) || matches(words, required: ["lower", "volume"]) ||
           matches(words, required: ["decrease", "volume"]) {
            return await adjustVolume(delta: -10)
        }
        if input == "mute" || matches(words, required: ["mute", "volume"]) || matches(words, required: ["mute", "audio"]) || matches(words, required: ["mute", "sound"]) {
            return try? await MuteVolumeTool().execute(arguments: "{}")
        }
        if input == "unmute" || matches(words, required: ["unmute", "volume"]) || matches(words, required: ["unmute", "audio"]) || matches(words, required: ["unmute", "sound"]) {
            return try? await UnmuteVolumeTool().execute(arguments: "{}")
        }
        if matches(words, required: ["max", "volume"]) || matches(words, required: ["full", "volume"]) || matches(words, required: ["maximum", "volume"]) {
            return try? await SetVolumeTool().execute(arguments: "{\"volume\": 100}")
        }
        if matches(words, required: ["set", "volume"]) {
            if let pct = extractPercentage(from: input) {
                return try? await SetVolumeTool().execute(arguments: "{\"volume\": \(pct)}")
            }
        }

        // Brightness
        if matches(words, required: ["brightness", "up"]) || matches(words, required: ["increase", "brightness"]) ||
           matches(words, required: ["brighter"]) {
            return await adjustBrightness(delta: 10)
        }
        if matches(words, required: ["brightness", "down"]) || matches(words, required: ["decrease", "brightness"]) ||
           matches(words, required: ["dim"]) || matches(words, required: ["dimmer"]) {
            return await adjustBrightness(delta: -10)
        }
        if matches(words, required: ["max", "brightness"]) || matches(words, required: ["full", "brightness"]) {
            return try? await SetBrightnessTool().execute(arguments: "{\"brightness\": 100}")
        }
        if matches(words, required: ["set", "brightness"]) {
            if let pct = extractPercentage(from: input) {
                return try? await SetBrightnessTool().execute(arguments: "{\"brightness\": \(pct)}")
            }
        }

        // Dark mode
        if input == "dark mode" || matches(words, required: ["dark", "mode", "on"]) || matches(words, required: ["turn", "on", "dark", "mode"]) ||
           matches(words, required: ["enable", "dark", "mode"]) || matches(words, required: ["switch", "dark", "mode"]) ||
           matches(words, required: ["go", "dark"]) {
            return try? await ToggleDarkModeTool().execute(arguments: "{\"enabled\": true}")
        }
        if input == "light mode" || matches(words, required: ["light", "mode", "on"]) || matches(words, required: ["turn", "on", "light", "mode"]) ||
           matches(words, required: ["disable", "dark", "mode"]) || matches(words, required: ["turn", "off", "dark", "mode"]) ||
           matches(words, required: ["go", "light"]) {
            return try? await ToggleDarkModeTool().execute(arguments: "{\"enabled\": false}")
        }
        if matches(words, required: ["toggle", "dark", "mode"]) {
            return try? await ToggleDarkModeTool().execute(arguments: "{}")
        }

        // Power / Lock
        if input == "lock screen" || input == "lock my mac" || input == "lock" || input == "lock my computer" ||
           matches(words, required: ["lock", "screen"]) || matches(words, required: ["lock", "mac"]) ||
           matches(words, required: ["lock", "computer"]) {
            return try? await LockScreenTool().execute(arguments: "{}")
        }
        if input == "sleep" || input == "go to sleep" || input == "sleep display" || matches(words, required: ["sleep", "display"]) ||
           input == "turn off screen" || input == "screen off" || matches(words, required: ["turn", "off", "display"]) {
            return try? await SleepDisplayTool().execute(arguments: "{}")
        }

        // Do Not Disturb
        if input == "do not disturb" || input == "dnd" || input == "dnd on" || input == "dnd off" ||
           matches(words, required: ["do", "not", "disturb"]) || matches(words, required: ["toggle", "dnd"]) ||
           input == "focus mode" || input == "silence notifications" {
            return try? await ToggleDNDTool().execute(arguments: "{}")
        }

        // Screenshot
        if input == "screenshot" || input == "take a screenshot" || input == "take screenshot" ||
           matches(words, required: ["take", "screenshot"]) || input == "screen capture" ||
           input == "capture screen" || input == "grab screen" {
            return try? await CaptureScreenTool().execute(arguments: "{}")
        }

        // Wi-Fi
        if input == "wifi on" || input == "turn on wifi" || input == "enable wifi" || matches(words, required: ["wifi", "on"]) || matches(words, required: ["turn", "on", "wifi"]) {
            return try? await ToggleWiFiTool().execute(arguments: "{\"enabled\": true}")
        }
        if input == "wifi off" || input == "turn off wifi" || input == "disable wifi" || matches(words, required: ["wifi", "off"]) || matches(words, required: ["turn", "off", "wifi"]) {
            return try? await ToggleWiFiTool().execute(arguments: "{\"enabled\": false}")
        }
        if input == "toggle wifi" || matches(words, required: ["toggle", "wifi"]) {
            return try? await ToggleWiFiTool().execute(arguments: "{}")
        }

        // Bluetooth
        if input == "bluetooth on" || input == "turn on bluetooth" || input == "enable bluetooth" || matches(words, required: ["bluetooth", "on"]) {
            return try? await ToggleBluetoothTool().execute(arguments: "{\"enabled\": true}")
        }
        if input == "bluetooth off" || input == "turn off bluetooth" || input == "disable bluetooth" || matches(words, required: ["bluetooth", "off"]) {
            return try? await ToggleBluetoothTool().execute(arguments: "{\"enabled\": false}")
        }
        if input == "toggle bluetooth" || matches(words, required: ["toggle", "bluetooth"]) {
            return try? await ToggleBluetoothTool().execute(arguments: "{}")
        }

        // Night shift
        if matches(words, required: ["night", "shift"]) || input == "night shift" {
            return try? await ToggleNightShiftTool().execute(arguments: "{}")
        }

        // Clipboard
        if input == "copy that" || input == "what did i copy" || input == "show clipboard" ||
           input == "what's on my clipboard" || input == "whats on my clipboard" ||
           matches(words, required: ["show", "clipboard"]) {
            return try? await GetClipboardTextTool().execute(arguments: "{}")
        }

        // System info
        if input == "system info" || input == "system information" || input == "about this mac" ||
           matches(words, required: ["system", "info"]) || matches(words, required: ["system", "information"]) {
            return try? await GetSystemInfoTool().execute(arguments: "{}")
        }

        // Empty trash
        if input == "empty trash" || input == "empty the trash" || matches(words, required: ["empty", "trash"]) {
            return try? await runAppleScript("tell application \"Finder\" to empty trash")
        }

        // Show desktop
        if input == "show desktop" || input == "hide all windows" || input == "minimize all" ||
           matches(words, required: ["show", "desktop"]) || matches(words, required: ["hide", "all", "windows"]) {
            return try? await runAppleScript("""
                tell application "System Events" to key code 103 using {command down, fn down}
            """)
        }

        // Notification / announce
        if input.hasPrefix("say ") || input.hasPrefix("announce ") || input.hasPrefix("speak ") {
            let text = extractAfterPrefix(input, prefixes: ["say ", "announce ", "speak "])
            if let text = text, !text.isEmpty {
                let jsonArg = "{\"text\": \"\(escapeJSON(text))\"}"
                return try? await SpeakTextTool().execute(arguments: jsonArg)
            }
        }

        // What's playing / now playing
        if input == "what's playing" || input == "whats playing" || input == "now playing" ||
           input == "current song" || input == "what song is this" ||
           matches(words, required: ["what's", "playing"]) || matches(words, required: ["currently", "playing"]) {
            return try? await MusicGetCurrentTool().execute(arguments: "{}")
        }

        // Not a simple command — fall through to LLM
        return nil
    }

    // MARK: - Messaging

    /// Handles "tell mom hi", "text Allen hey", "给妈妈发晚上好" etc.
    /// Uses MessageParser for extraction and SendMessageTool for delivery.
    private func tryMessagingCommand(_ command: String) async -> String? {
        guard let parsed = MessageParser.parse(command) else { return nil }

        let contactJSON = parsed.contact.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let messageJSON = parsed.message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let args = "{\"contact\": \"\(contactJSON)\", \"message\": \"\(messageJSON)\", \"platform\": \"auto\"}"
        return try? await SendMessageTool().execute(arguments: args)
    }
}
