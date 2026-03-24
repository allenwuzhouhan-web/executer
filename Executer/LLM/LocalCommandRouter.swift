import Foundation
import CoreGraphics
import AppKit

/// Routes simple, unambiguous commands directly to executors without calling the LLM API.
/// This makes common actions (volume, brightness, app launch, music, web, etc.) feel instant.
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

    // MARK: - App Commands

    private func tryAppCommand(_ input: String) async -> String? {
        let prefixes = [
            ("open ", "launch"), ("launch ", "launch"), ("start ", "launch"),
            ("quit ", "quit"), ("close ", "quit"), ("kill ", "quit"),
            ("switch to ", "switch"), ("go to ", "switch"), ("bring up ", "switch"),
        ]
        for (prefix, action) in prefixes {
            if input.hasPrefix(prefix) {
                let appName = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !appName.isEmpty else { continue }
                // Don't intercept ambiguous commands like "open the file..." or web navigation
                let nonAppWords = ["file", "files", "folder", "window", "tab", "url", "link", "page", "document",
                                   "youtube", "google", "safari", "http", "www", "website", ".com", ".org", ".net"]
                if nonAppWords.contains(where: { appName.lowercased().contains($0) }) {
                    return nil
                }
                let jsonArg = "{\"app_name\": \"\(escapeJSON(appName))\"}"
                switch action {
                case "launch":
                    return try? await LaunchAppTool().execute(arguments: jsonArg)
                case "quit":
                    return try? await QuitAppTool().execute(arguments: jsonArg)
                case "switch":
                    return try? await SwitchToAppTool().execute(arguments: jsonArg)
                default:
                    break
                }
            }
        }

        // "hide [app]"
        if input.hasPrefix("hide ") {
            let appName = String(input.dropFirst("hide ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !appName.isEmpty && appName != "all windows" {
                return try? await HideAppTool().execute(arguments: "{\"app_name\": \"\(escapeJSON(appName))\"}")
            }
        }

        return nil
    }

    // MARK: - Web Navigation

    private func tryWebNavigation(_ input: String) async -> String? {
        // "go to [url]" / "navigate to [url]" / "open [url]"
        let navPrefixes = ["go to ", "navigate to ", "open "]
        for prefix in navPrefixes {
            if input.hasPrefix(prefix) {
                let target = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = resolveURL(target) {
                    let jsonArg = "{\"url\": \"\(escapeJSON(url))\"}"
                    return try? await OpenInSafariTool().execute(arguments: jsonArg)
                }
            }
        }

        // "[url] in safari" / "open [url] in safari"
        if input.contains(" in safari") {
            let target = input.replacingOccurrences(of: " in safari", with: "")
                .replacingOccurrences(of: "open ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = resolveURL(target) {
                let jsonArg = "{\"url\": \"\(escapeJSON(url))\"}"
                return try? await OpenInSafariTool().execute(arguments: jsonArg)
            }
        }

        // "new tab [url]" / "new tab with [url]"
        if input.hasPrefix("new tab ") {
            let target = input.replacingOccurrences(of: "new tab with ", with: "")
                .replacingOccurrences(of: "new tab ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = resolveURL(target) {
                let jsonArg = "{\"url\": \"\(escapeJSON(url))\"}"
                return try? await NewSafariTabTool().execute(arguments: jsonArg)
            }
        }

        return nil
    }

    // MARK: - Search Commands

    private func trySearchCommand(_ input: String) async -> String? {
        // "search youtube for [query]" / "youtube [query]" / "search [query] on youtube"
        if let query = extractSearchQuery(input, platform: "youtube") {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let url = "https://www.youtube.com/results?search_query=\(encoded)"
            return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
        }

        // "search google for [query]" / "google [query]"
        if let query = extractSearchQuery(input, platform: "google") {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            return try? await SearchWebTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\"}")
        }

        // "search for [query]" / "look up [query]" / "search [query]"
        let searchPrefixes = ["search for ", "look up ", "search "]
        for prefix in searchPrefixes {
            if input.hasPrefix(prefix) {
                let query = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Don't match "search youtube/google" — those are handled above
                if !query.isEmpty && !query.hasPrefix("youtube") && !query.hasPrefix("google") &&
                   !query.contains(" on youtube") && !query.contains(" on google") {
                    return try? await SearchWebTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\"}")
                }
            }
        }

        // "search [query] on [platform]"
        if input.hasPrefix("search ") && input.contains(" on ") {
            let afterSearch = String(input.dropFirst("search ".count))
            if let onRange = afterSearch.range(of: " on ", options: .backwards) {
                let query = String(afterSearch[afterSearch.startIndex..<onRange.lowerBound])
                let platform = String(afterSearch[onRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

                if !query.isEmpty {
                    if let url = searchURLForPlatform(platform, query: query) {
                        return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
                    }
                }
            }
        }

        // "watch [query]" — assume YouTube
        if input.hasPrefix("watch ") {
            let query = String(input.dropFirst("watch ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                let url = "https://www.youtube.com/results?search_query=\(encoded)"
                return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
            }
        }

        return nil
    }

    // MARK: - Music Commands

    private func tryMusicCommand(_ input: String, words: Set<String>) async -> String? {
        if input == "pause" || input == "pause music" || input == "stop music" || matches(words, required: ["pause", "music"]) {
            return try? await MusicPauseTool().execute(arguments: "{}")
        }
        if input == "play music" || input == "resume music" || input == "resume" ||
           matches(words, required: ["resume", "music"]) || input == "unpause" || input == "unpause music" {
            return try? await MusicPlayTool().execute(arguments: "{}")
        }
        // "play [song name]" — route to MusicPlaySongTool for specific songs
        if input.hasPrefix("play ") && !input.hasPrefix("play music") {
            let songQuery = String(input.dropFirst("play ".count)).trimmingCharacters(in: .whitespaces)
            if !songQuery.isEmpty {
                let jsonArg = "{\"query\": \"\(escapeJSON(songQuery))\"}"
                return try? await MusicPlaySongTool().execute(arguments: jsonArg)
            }
        }
        if input == "next track" || input == "skip" || input == "next song" || input == "skip track" || input == "skip song" ||
           matches(words, required: ["next", "track"]) || matches(words, required: ["next", "song"]) ||
           input == "skip this" || input == "next" {
            return try? await MusicNextTool().execute(arguments: "{}")
        }
        if input == "previous track" || input == "previous song" || input == "last track" || input == "last song" ||
           matches(words, required: ["previous", "track"]) || matches(words, required: ["previous", "song"]) ||
           input == "go back" || input == "previous" {
            return try? await MusicPreviousTool().execute(arguments: "{}")
        }
        if input == "shuffle" || input == "shuffle on" || input == "shuffle off" || input == "toggle shuffle" ||
           matches(words, required: ["toggle", "shuffle"]) || matches(words, required: ["turn", "on", "shuffle"]) {
            return try? await MusicToggleShuffleTool().execute(arguments: "{}")
        }
        // "set music volume to X"
        if (input.contains("music volume") || input.contains("song volume")) {
            if let pct = extractPercentage(from: input) {
                return try? await MusicSetVolumeTool().execute(arguments: "{\"volume\": \(pct)}")
            }
        }

        return nil
    }

    // MARK: - Timer / Reminder

    private func tryTimerReminder(_ input: String) async -> String? {
        // "set a timer for X minutes" / "timer X minutes" / "X minute timer"
        if input.contains("timer") || input.contains("set a timer") {
            if let seconds = extractTimerSeconds(from: input) {
                return try? await SetTimerTool().execute(arguments: "{\"duration_seconds\": \(seconds), \"label\": \"Timer\"}")
            }
        }

        // "remind me to [task]" / "reminder: [task]"
        let reminderPrefixes = ["remind me to ", "remind me ", "reminder ", "reminder: "]
        for prefix in reminderPrefixes {
            if input.hasPrefix(prefix) {
                let task = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !task.isEmpty {
                    return try? await CreateReminderTool().execute(arguments: "{\"title\": \"\(escapeJSON(task))\"}")
                }
            }
        }

        // "note: [text]" / "take a note [text]" / "make a note [text]"
        let notePrefixes = ["note: ", "note ", "take a note ", "make a note "]
        for prefix in notePrefixes {
            if input.hasPrefix(prefix) {
                let text = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return try? await CreateNoteTool().execute(arguments: "{\"title\": \"Quick Note\", \"body\": \"\(escapeJSON(text))\"}")
                }
            }
        }

        return nil
    }

    // MARK: - Cursor Commands

    private func tryCursorCommand(_ input: String, words: Set<String>) async -> String? {
        // Click
        if input == "click" || input == "click here" {
            return try? await ClickTool().execute(arguments: "{}")
        }
        if input == "double click" || input == "double-click" {
            return try? await ClickTool().execute(arguments: "{\"count\": 2}")
        }
        if input == "right click" || input == "right-click" {
            return try? await ClickTool().execute(arguments: "{\"button\": \"right\"}")
        }

        // Scroll
        if input == "scroll down" || matches(words, required: ["scroll", "down"]) {
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"down\"}")
        }
        if input == "scroll up" || matches(words, required: ["scroll", "up"]) {
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"up\"}")
        }
        if input == "scroll left" || matches(words, required: ["scroll", "left"]) {
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"left\"}")
        }
        if input == "scroll right" || matches(words, required: ["scroll", "right"]) {
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"right\"}")
        }
        // "scroll down a lot" / "scroll way down"
        if (input.contains("scroll") && input.contains("lot")) || (input.contains("scroll") && input.contains("way")) {
            let dir = input.contains("up") ? "up" : "down"
            return try? await ScrollTool().execute(arguments: "{\"direction\": \"\(dir)\", \"amount\": 8}")
        }

        // Move cursor to center
        if input == "move cursor to center" || input == "center cursor" || matches(words, required: ["cursor", "center"]) {
            if let screen = NSScreen.main {
                let x = Int(screen.frame.width / 2)
                let y = Int(screen.frame.height / 2)
                return try? await MoveCursorTool().execute(arguments: "{\"x\": \(x), \"y\": \(y)}")
            }
        }

        // Where is cursor
        if input == "where is my cursor" || input == "cursor position" || input == "where's the cursor" ||
           matches(words, required: ["cursor", "position"]) {
            return try? await GetCursorPositionTool().execute(arguments: "{}")
        }

        // "click on [element]"
        if input.hasPrefix("click on ") || input.hasPrefix("click the ") || input.hasPrefix("press the ") || input.hasPrefix("tap ") {
            let desc = input
                .replacingOccurrences(of: "click on ", with: "")
                .replacingOccurrences(of: "click the ", with: "")
                .replacingOccurrences(of: "press the ", with: "")
                .replacingOccurrences(of: "tap ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty {
                return try? await ClickElementTool().execute(arguments: "{\"description\": \"\(escapeJSON(desc))\"}")
            }
        }

        return nil
    }

    // MARK: - Keyboard Commands

    private func tryKeyboardCommand(_ input: String) async -> String? {
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

    // MARK: - Dictionary / Definition Commands

    private func tryDictionaryCommand(_ input: String) async -> String? {
        // "define [word]" / "definition of [word]" / "what does [word] mean"
        let definePrefixes = ["define ", "definition of ", "definition for "]
        for prefix in definePrefixes {
            if input.hasPrefix(prefix) {
                let word = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !word.isEmpty {
                    return try? await DictionaryLookupTool().execute(arguments: "{\"word\": \"\(escapeJSON(word))\"}")
                }
            }
        }

        // "what does [word] mean"
        if input.hasPrefix("what does ") && input.hasSuffix(" mean") {
            let word = String(input.dropFirst("what does ".count).dropLast(" mean".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                return try? await DictionaryLookupTool().execute(arguments: "{\"word\": \"\(escapeJSON(word))\"}")
            }
        }

        // "what's the meaning of [word]"
        if input.hasPrefix("what's the meaning of ") || input.hasPrefix("whats the meaning of ") {
            let prefix = input.hasPrefix("what's") ? "what's the meaning of " : "whats the meaning of "
            let word = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                return try? await DictionaryLookupTool().execute(arguments: "{\"word\": \"\(escapeJSON(word))\"}")
            }
        }

        // "synonym for [word]" / "synonyms of [word]"
        let synPrefixes = ["synonym for ", "synonyms for ", "synonyms of ", "synonym of ",
                           "another word for ", "similar word to ", "similar words to "]
        for prefix in synPrefixes {
            if input.hasPrefix(prefix) {
                let word = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !word.isEmpty {
                    return try? await ThesaurusLookupTool().execute(arguments: "{\"word\": \"\(escapeJSON(word))\"}")
                }
            }
        }

        // "spell check [text]" / "how do you spell [word]" / "is [word] spelled right"
        if input.hasPrefix("spell check ") || input.hasPrefix("spellcheck ") {
            let text = input.replacingOccurrences(of: "spell check ", with: "")
                .replacingOccurrences(of: "spellcheck ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return try? await SpellCheckTool().execute(arguments: "{\"text\": \"\(escapeJSON(text))\"}")
            }
        }
        if input.hasPrefix("how do you spell ") {
            let word = String(input.dropFirst("how do you spell ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                return try? await SpellCheckTool().execute(arguments: "{\"text\": \"\(escapeJSON(word))\"}")
            }
        }

        return nil
    }

    // MARK: - Translation (simple, local — just display it, no API)

    private func tryTranslation(_ input: String) async -> String? {
        // This catches "translate X to Y" but we return nil to let the LLM handle
        // the actual translation. The point is to NOT do research — just translate.
        // The LLM will handle it as a simple task.
        return nil
    }

    // MARK: - URL Resolution

    /// Tries to resolve a spoken/typed target into a valid URL.
    private func resolveURL(_ target: String) -> String? {
        let clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // Already a URL
        if clean.hasPrefix("http://") || clean.hasPrefix("https://") {
            return clean
        }

        // Looks like a domain (contains a dot, no spaces)
        if clean.contains(".") && !clean.contains(" ") {
            return "https://\(clean)"
        }

        // Common site shortcuts
        let shortcuts: [String: String] = [
            "youtube": "https://www.youtube.com",
            "google": "https://www.google.com",
            "gmail": "https://mail.google.com",
            "twitter": "https://x.com",
            "x": "https://x.com",
            "reddit": "https://www.reddit.com",
            "github": "https://github.com",
            "facebook": "https://www.facebook.com",
            "instagram": "https://www.instagram.com",
            "linkedin": "https://www.linkedin.com",
            "amazon": "https://www.amazon.com",
            "netflix": "https://www.netflix.com",
            "spotify": "https://open.spotify.com",
            "twitch": "https://www.twitch.tv",
            "discord": "https://discord.com/app",
            "slack": "https://app.slack.com",
            "notion": "https://www.notion.so",
            "figma": "https://www.figma.com",
            "chatgpt": "https://chat.openai.com",
            "claude": "https://claude.ai",
            "hacker news": "https://news.ycombinator.com",
            "hackernews": "https://news.ycombinator.com",
            "hn": "https://news.ycombinator.com",
            "stack overflow": "https://stackoverflow.com",
            "stackoverflow": "https://stackoverflow.com",
            "wikipedia": "https://en.wikipedia.org",
            "maps": "https://maps.google.com",
            "google maps": "https://maps.google.com",
            "google drive": "https://drive.google.com",
            "drive": "https://drive.google.com",
            "docs": "https://docs.google.com",
            "google docs": "https://docs.google.com",
            "sheets": "https://sheets.google.com",
            "google sheets": "https://sheets.google.com",
            "calendar": "https://calendar.google.com",
            "google calendar": "https://calendar.google.com",
            "whatsapp": "https://web.whatsapp.com",
            "telegram": "https://web.telegram.org",
            "tiktok": "https://www.tiktok.com",
            "pinterest": "https://www.pinterest.com",
            "ebay": "https://www.ebay.com",
            "apple music": "https://music.apple.com",
        ]

        if let url = shortcuts[clean] {
            return url
        }

        return nil
    }

    // MARK: - Search Query Extraction

    /// Extract search query for a specific platform from various natural phrasings.
    private func extractSearchQuery(_ input: String, platform: String) -> String? {
        // "search [platform] for [query]"
        if input.hasPrefix("search \(platform) for ") {
            let query = String(input.dropFirst("search \(platform) for ".count))
            return query.isEmpty ? nil : query
        }

        // "search for [query] on [platform]"
        if input.hasPrefix("search for ") && input.hasSuffix(" on \(platform)") {
            let withoutPrefix = String(input.dropFirst("search for ".count))
            let query = String(withoutPrefix.dropLast(" on \(platform)".count))
            return query.isEmpty ? nil : query
        }

        // "search [query] on [platform]"
        if input.hasPrefix("search ") && input.hasSuffix(" on \(platform)") {
            let withoutPrefix = String(input.dropFirst("search ".count))
            let query = String(withoutPrefix.dropLast(" on \(platform)".count))
            return query.isEmpty ? nil : query
        }

        // "[platform] [query]" (e.g., "youtube funny cats")
        if input.hasPrefix("\(platform) ") {
            let query = String(input.dropFirst("\(platform) ".count))
            return query.isEmpty ? nil : query
        }

        // "[query] on [platform]"
        if input.hasSuffix(" on \(platform)") {
            let query = String(input.dropLast(" on \(platform)".count))
            // Filter out things that don't look like search queries
            if !query.isEmpty && !query.hasPrefix("search") && !query.hasPrefix("look") {
                return query
            }
        }

        // "find [query] on [platform]"
        if input.hasPrefix("find ") && input.hasSuffix(" on \(platform)") {
            let withoutPrefix = String(input.dropFirst("find ".count))
            let query = String(withoutPrefix.dropLast(" on \(platform)".count))
            return query.isEmpty ? nil : query
        }

        return nil
    }

    /// Build a search URL for a given platform.
    private func searchURLForPlatform(_ platform: String, query: String) -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch platform.lowercased() {
        case "youtube":
            return "https://www.youtube.com/results?search_query=\(encoded)"
        case "google":
            return "https://www.google.com/search?q=\(encoded)"
        case "reddit":
            return "https://www.reddit.com/search/?q=\(encoded)"
        case "amazon":
            return "https://www.amazon.com/s?k=\(encoded)"
        case "github":
            return "https://github.com/search?q=\(encoded)"
        case "twitter", "x":
            return "https://x.com/search?q=\(encoded)"
        case "wikipedia":
            return "https://en.wikipedia.org/w/index.php?search=\(encoded)"
        case "stack overflow", "stackoverflow":
            return "https://stackoverflow.com/search?q=\(encoded)"
        case "spotify":
            return "https://open.spotify.com/search/\(encoded)"
        default:
            return nil
        }
    }

    // MARK: - Volume / Brightness Adjustment

    private func adjustVolume(delta: Int) async -> String? {
        let currentStr = (try? await GetVolumeTool().execute(arguments: "{}")) ?? ""
        let digits = currentStr.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        let current = Int(digits) ?? 50
        let newLevel = max(0, min(100, current + delta))
        return try? await SetVolumeTool().execute(arguments: "{\"volume\": \(newLevel)}")
    }

    private func adjustBrightness(delta: Int) async -> String? {
        let currentStr = (try? await GetBrightnessTool().execute(arguments: "{}")) ?? ""
        let digits = currentStr.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        let current = Int(digits) ?? 50
        let newLevel = max(0, min(100, current + delta))
        return try? await SetBrightnessTool().execute(arguments: "{\"brightness\": \(newLevel)}")
    }

    // MARK: - Helpers

    private func matches(_ words: Set<String>, required: Set<String>) -> Bool {
        return required.isSubset(of: words)
    }

    private func escapeJSON(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func extractAfterPrefix(_ input: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            if input.hasPrefix(prefix) {
                return String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Extract a number from phrases like "set volume to 50" or "50%"
    private func extractPercentage(from input: String) -> Int? {
        let pattern = #"(\d+)\s*%?"#
        if let match = input.range(of: pattern, options: .regularExpression) {
            let numStr = input[match].trimmingCharacters(in: CharacterSet(charactersIn: "% "))
            return Int(numStr)
        }
        // Also try "to [number]"
        if let toRange = input.range(of: "to ") {
            let afterTo = input[toRange.upperBound...]
            let numStr = afterTo.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).first ?? ""
            if let num = Int(numStr.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) {
                return max(0, min(100, num))
            }
        }
        return nil
    }

    /// Extract seconds from timer phrases like "5 minutes", "30 seconds", "1 hour"
    private func extractTimerSeconds(from input: String) -> Int? {
        let pattern = #"(\d+)\s*(minute|min|minutes|mins|second|seconds|sec|secs|hour|hours|hr|hrs)"#
        guard let match = input.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(input[match])
        let numStr = matched.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        guard let num = Int(numStr) else { return nil }

        if matched.contains("hour") || matched.contains("hr") {
            return num * 3600
        } else if matched.contains("second") || matched.contains("sec") {
            return num
        }
        return num * 60 // minutes → seconds
    }

    private func runAppleScript(_ script: String) async throws -> String {
        return try AppleScriptRunner.runThrowing(script)
    }
}
