#!/usr/bin/env swift
// Standalone test harness for all dynamic pattern matchers.
// Tests pure parsing logic — no app dependencies needed.

import Foundation

// ═══════════════════════════════════════════════════════════════
// MARK: - Test Infrastructure
// ═══════════════════════════════════════════════════════════════

var passed = 0
var failed = 0
var currentGroup = ""

func group(_ name: String) {
    currentGroup = name
    print("\n\u{001B}[1m── \(name) ──\u{001B}[0m")
}

func assert(_ condition: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
        print("  \u{001B}[32m✓\u{001B}[0m \(msg)")
    } else {
        failed += 1
        print("  \u{001B}[31m✗\u{001B}[0m \(msg)  [\(file):\(line)]")
    }
}

func assertEqual<T: Equatable>(_ a: T?, _ b: T?, _ msg: String) {
    if a == b {
        passed += 1
        print("  \u{001B}[32m✓\u{001B}[0m \(msg)")
    } else {
        failed += 1
        print("  \u{001B}[31m✗\u{001B}[0m \(msg)  — got \(String(describing: a)), expected \(String(describing: b))")
    }
}

// ═══════════════════════════════════════════════════════════════
// MARK: - 1. Translation Detection (SmartRouter)
// ═══════════════════════════════════════════════════════════════

func isTranslation(_ input: String) -> Bool {
    let cmd = input.lowercased()
    if cmd.hasPrefix("translate") || cmd.contains("translate this") { return true }
    if cmd.hasPrefix("how do you say ") || cmd.hasPrefix("how to say ") { return true }
    for prep in [" to ", " in "] {
        if let range = cmd.range(of: prep, options: .backwards) {
            let after = String(cmd[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let words = after.split(separator: " ")
            if words.count >= 1 && words.count <= 2 && words.allSatisfy({ $0.allSatisfy({ $0.isLetter }) }) {
                let before = String(cmd[cmd.startIndex..<range.lowerBound])
                let firstWord = before.split(separator: " ").first.map(String.init) ?? before
                let actionWords = ["go", "open", "switch", "move", "set", "add",
                                   "send", "play", "save", "connect", "navigate"]
                if actionWords.contains(firstWord) { return false }
                return true
            }
        }
    }
    return false
}

group("1. Translation Detection")
assert(isTranslation("translate hello to spanish"), "translate X to spanish")
assert(isTranslation("translate this to japanese"), "translate this to japanese")
assert(isTranslation("how do you say hello in french"), "how do you say X in french")
assert(isTranslation("hello in korean"), "X in korean")
assert(isTranslation("good morning in mandarin chinese"), "X in mandarin chinese (2-word lang)")
assert(isTranslation("what is love in swahili"), "X in swahili (uncommon language)")
assert(isTranslation("cat to portuguese"), "X to portuguese")
assert(isTranslation("translate bonjour to english"), "translate X to english")
assert(!isTranslation("go to settings"), "NOT: go to settings")
assert(!isTranslation("open safari to google"), "NOT: open safari to google")
assert(!isTranslation("play music in spotify"), "NOT: play music in spotify")
assert(!isTranslation("send email to john"), "NOT: send email to john")
assert(!isTranslation("connect to bluetooth"), "NOT: connect to bluetooth")
assert(!isTranslation("navigate to home"), "NOT: navigate to home")

// ═══════════════════════════════════════════════════════════════
// MARK: - 2. System Settings Pane Resolution
// ═══════════════════════════════════════════════════════════════

let settingsPaneAliases: [String: String] = [
    "wifi": "Wi-Fi", "wi-fi": "Wi-Fi",
    "audio": "Sound",
    "screen": "Displays", "monitor": "Displays",
    "mouse": "Mouse",
    "privacy": "Privacy & Security",
    "wallpaper": "Wallpaper",
    "screensaver": "Screen Saver", "screen saver": "Screen Saver",
    "dock": "Desktop & Dock",
    "users": "Users & Groups", "accounts": "Users & Groups",
    "sharing": "General",
    "printers": "Printers & Scanners",
    "storage": "General",
    "login items": "General",
]

func resolveSettingsPane(_ input: String) -> String {
    let lower = input.lowercased()
    if let alias = settingsPaneAliases[lower] { return alias }
    return lower.split(separator: " ").map { word in
        word.prefix(1).uppercased() + word.dropFirst()
    }.joined(separator: " ")
}

group("2. System Settings Pane Resolution")
assertEqual(resolveSettingsPane("wifi"), "Wi-Fi", "wifi → Wi-Fi")
assertEqual(resolveSettingsPane("wi-fi"), "Wi-Fi", "wi-fi → Wi-Fi")
assertEqual(resolveSettingsPane("bluetooth"), "Bluetooth", "bluetooth → Bluetooth (title-cased)")
assertEqual(resolveSettingsPane("audio"), "Sound", "audio → Sound (alias)")
assertEqual(resolveSettingsPane("privacy"), "Privacy & Security", "privacy → Privacy & Security")
assertEqual(resolveSettingsPane("screen saver"), "Screen Saver", "screen saver → Screen Saver (alias)")
assertEqual(resolveSettingsPane("keyboard"), "Keyboard", "keyboard → Keyboard (dynamic title-case)")
assertEqual(resolveSettingsPane("trackpad"), "Trackpad", "trackpad → Trackpad (dynamic)")
assertEqual(resolveSettingsPane("focus"), "Focus", "focus → Focus (dynamic, not hardcoded)")
assertEqual(resolveSettingsPane("accessibility"), "Accessibility", "accessibility → Accessibility (dynamic)")
assertEqual(resolveSettingsPane("siri"), "Siri", "siri → Siri (dynamic)")
assertEqual(resolveSettingsPane("time machine"), "Time Machine", "time machine → Time Machine (multi-word)")
assertEqual(resolveSettingsPane("lock screen"), "Lock Screen", "lock screen → Lock Screen (dynamic)")

// ═══════════════════════════════════════════════════════════════
// MARK: - 3. Hotkey Combo Parsing
// ═══════════════════════════════════════════════════════════════

func parseHotkeyCombo(_ raw: String) -> String? {
    let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
    let separator: Character
    if lower.contains("+") { separator = "+" }
    else if lower.contains("-") && lower.count > 3 { separator = "-" }
    else { return nil }

    let parts = lower.split(separator: separator).map { String($0).trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 2 else { return nil }

    let modifierMap: [String: String] = [
        "cmd": "cmd", "command": "cmd",
        "ctrl": "ctrl", "control": "ctrl",
        "opt": "option", "option": "option", "alt": "option",
        "shift": "shift", "fn": "fn",
    ]

    var modifiers: [String] = []
    var key: String?

    for part in parts {
        if let mod = modifierMap[part] {
            modifiers.append(mod)
        } else {
            key = part
        }
    }

    guard !modifiers.isEmpty, let finalKey = key, !finalKey.isEmpty else { return nil }
    let order = ["cmd", "ctrl", "option", "shift", "fn"]
    modifiers.sort { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    return (modifiers + [finalKey]).joined(separator: "+")
}

group("3. Hotkey Combo Parsing")
assertEqual(parseHotkeyCombo("cmd+c"), "cmd+c", "cmd+c")
assertEqual(parseHotkeyCombo("command+c"), "cmd+c", "command+c → cmd+c")
assertEqual(parseHotkeyCombo("ctrl+shift+a"), "ctrl+shift+a", "ctrl+shift+a")
assertEqual(parseHotkeyCombo("command+option+escape"), "cmd+option+escape", "command+option+escape")
assertEqual(parseHotkeyCombo("shift+cmd+z"), "cmd+shift+z", "shift+cmd+z → sorted: cmd+shift+z")
assertEqual(parseHotkeyCombo("alt+f4"), "option+f4", "alt+f4 → option+f4")
assertEqual(parseHotkeyCombo("ctrl+alt+delete"), "ctrl+option+delete", "ctrl+alt+delete")
assertEqual(parseHotkeyCombo("cmd+shift+ctrl+p"), "cmd+ctrl+shift+p", "3 modifiers sorted")
assertEqual(parseHotkeyCombo("fn+f11"), "fn+f11", "fn+f11")
assertEqual(parseHotkeyCombo("cmd-k"), "cmd+k", "cmd-k (dash separator)")
assertEqual(parseHotkeyCombo("hello"), nil, "NOT: plain word")
assertEqual(parseHotkeyCombo("a+b"), nil, "NOT: no modifiers")

// ═══════════════════════════════════════════════════════════════
// MARK: - 4. Key Name Resolution
// ═══════════════════════════════════════════════════════════════

func resolveKeyName(_ raw: String) -> String? {
    let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
    guard !lower.isEmpty else { return nil }

    let directKeys: Set<String> = [
        "enter", "return", "tab", "escape", "space",
        "delete", "backspace", "forwarddelete",
        "home", "end", "pageup", "pagedown",
        "up", "down", "left", "right",
        "capslock", "shift", "control", "option", "command",
    ]
    if directKeys.contains(lower) { return lower }

    let keyAliases: [String: String] = [
        "arrow up": "up", "arrow down": "down",
        "arrow left": "left", "arrow right": "right",
        "up arrow": "up", "down arrow": "down",
        "left arrow": "left", "right arrow": "right",
        "page up": "pageup", "page down": "pagedown",
        "forward delete": "forwarddelete",
        "esc": "escape", "ret": "return", "del": "delete",
        "caps lock": "capslock", "caps": "capslock",
        "ctrl": "control", "cmd": "command", "opt": "option", "alt": "option",
    ]
    if let resolved = keyAliases[lower] { return resolved }

    if lower.hasPrefix("f"), let num = Int(lower.dropFirst(1)), num >= 1 && num <= 20 {
        return lower
    }

    return nil
}

group("4. Key Name Resolution")
assertEqual(resolveKeyName("enter"), "enter", "enter")
assertEqual(resolveKeyName("tab"), "tab", "tab")
assertEqual(resolveKeyName("escape"), "escape", "escape")
assertEqual(resolveKeyName("esc"), "escape", "esc → escape")
assertEqual(resolveKeyName("arrow up"), "up", "arrow up → up")
assertEqual(resolveKeyName("down arrow"), "down", "down arrow → down")
assertEqual(resolveKeyName("page down"), "pagedown", "page down → pagedown")
assertEqual(resolveKeyName("page up"), "pageup", "page up → pageup")
assertEqual(resolveKeyName("home"), "home", "home")
assertEqual(resolveKeyName("end"), "end", "end")
assertEqual(resolveKeyName("f1"), "f1", "f1")
assertEqual(resolveKeyName("f5"), "f5", "f5")
assertEqual(resolveKeyName("f12"), "f12", "f12")
assertEqual(resolveKeyName("f20"), "f20", "f20")
assertEqual(resolveKeyName("caps lock"), "capslock", "caps lock → capslock")
assertEqual(resolveKeyName("forward delete"), "forwarddelete", "forward delete")
assertEqual(resolveKeyName("alt"), "option", "alt → option")
assertEqual(resolveKeyName("blah"), nil, "NOT: unknown key")

// ═══════════════════════════════════════════════════════════════
// MARK: - 5. File Extension Detection (Dynamic Regex)
// ═══════════════════════════════════════════════════════════════

let fileExtensionPattern = try! NSRegularExpression(pattern: #"\.\w{1,5}$"#)
let domainTLDs: Set<String> = ["com", "org", "net", "io", "co", "ai", "app", "dev", "tv"]

func looksLikeFilePath(_ target: String) -> Bool {
    if target.contains("/") || target.hasPrefix("~") { return true }
    let trimmed = target.trimmingCharacters(in: .whitespaces)
    let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
    if fileExtensionPattern.firstMatch(in: trimmed, range: nsRange) != nil {
        if trimmed.contains(" ") { return true }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return !domainTLDs.contains(ext)
    }
    return false
}

group("5. File Extension Detection")
assert(looksLikeFilePath("report.pdf"), "report.pdf")
assert(looksLikeFilePath("notes.txt"), "notes.txt")
assert(looksLikeFilePath("photo.jpeg"), "photo.jpeg")
assert(looksLikeFilePath("script.py"), "script.py")
assert(looksLikeFilePath("data.csv"), "data.csv")
assert(looksLikeFilePath("movie.mkv"), "movie.mkv")
assert(looksLikeFilePath("archive.tar"), "archive.tar")
assert(looksLikeFilePath("game.exe"), "game.exe (any extension works)")
assert(looksLikeFilePath("model.onnx"), "model.onnx (ML file)")
assert(looksLikeFilePath("file.rs"), "file.rs (Rust)")
assert(looksLikeFilePath("my report.docx"), "my report.docx (with space)")
assert(looksLikeFilePath("~/Documents/notes.txt"), "~/Documents/notes.txt (path)")
assert(looksLikeFilePath("/tmp/test.log"), "/tmp/test.log (absolute path)")
assert(!looksLikeFilePath("google.com"), "NOT: google.com (domain)")
assert(!looksLikeFilePath("example.org"), "NOT: example.org (domain)")
assert(!looksLikeFilePath("myapp.io"), "NOT: myapp.io (domain)")
assert(!looksLikeFilePath("hello"), "NOT: hello (no extension)")
assert(!looksLikeFilePath("reddit.co"), "NOT: reddit.co (domain)")

// ═══════════════════════════════════════════════════════════════
// MARK: - 6. Music Query Builder
// ═══════════════════════════════════════════════════════════════

func buildMusicQuery(_ raw: String) -> String {
    var text = raw
    if let byRange = text.range(of: " by ", options: .caseInsensitive) {
        text = String(text[text.startIndex..<byRange.lowerBound]) + " " +
               String(text[byRange.upperBound...])
    }
    let stripPrefixes = ["the song ", "the album ", "the playlist ", "the artist ",
                         "my playlist ", "the ep ", "album ", "playlist ", "song ",
                         "some ", "a little ", "something by ", "something "]
    for prefix in stripPrefixes {
        if text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
    }
    for suffix in [" on repeat", " on shuffle", " on loop"] {
        if text.lowercased().hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
    }
    return text.trimmingCharacters(in: .whitespaces)
}

group("6. Music Query Builder")
assertEqual(buildMusicQuery("Shape of You by Ed Sheeran"), "Shape of You Ed Sheeran", "Song by Artist → flat query")
assertEqual(buildMusicQuery("the album Thriller"), "Thriller", "the album X → X")
assertEqual(buildMusicQuery("my playlist Chill Vibes"), "Chill Vibes", "my playlist X → X")
assertEqual(buildMusicQuery("some jazz"), "jazz", "some X → X")
assertEqual(buildMusicQuery("Bohemian Rhapsody on repeat"), "Bohemian Rhapsody", "X on repeat → X")
assertEqual(buildMusicQuery("the song Imagine"), "Imagine", "the song X → X")
assertEqual(buildMusicQuery("something by Taylor Swift"), "Taylor Swift", "something by X → X")
assertEqual(buildMusicQuery("a little classical music"), "classical music", "a little X → X")
assertEqual(buildMusicQuery("Blinding Lights"), "Blinding Lights", "plain query unchanged")

// ═══════════════════════════════════════════════════════════════
// MARK: - 7. Scroll Amount Parsing
// ═══════════════════════════════════════════════════════════════

let scrollAmountPattern = try! NSRegularExpression(pattern: #"(\d+)\s*(times?)?"#)

func parseScrollAmount(_ input: String) -> Int? {
    let nsRange = NSRange(input.startIndex..., in: input)
    guard let match = scrollAmountPattern.firstMatch(in: input, range: nsRange),
          let numRange = Range(match.range(at: 1), in: input),
          let num = Int(input[numRange]) else { return nil }
    return num
}

group("7. Scroll Amount Parsing")
assertEqual(parseScrollAmount("scroll down 5"), 5, "scroll down 5 → 5")
assertEqual(parseScrollAmount("scroll up 3 times"), 3, "scroll up 3 times → 3")
assertEqual(parseScrollAmount("scroll down 10 times"), 10, "scroll down 10 times → 10")
assertEqual(parseScrollAmount("scroll down 1"), 1, "scroll down 1 → 1")
assertEqual(parseScrollAmount("scroll down"), nil, "scroll down (no number) → nil")

// ═══════════════════════════════════════════════════════════════
// MARK: - 8. Compound Duration Parsing
// ═══════════════════════════════════════════════════════════════

let durationComponentPattern = try! NSRegularExpression(
    pattern: #"(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?=\d|\s|$)"#,
    options: .caseInsensitive
)
let colonDurationPattern = try! NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})(?::(\d{2}))?"#)

func parseCompoundDuration(_ input: String) -> Int? {
    let nsRange = NSRange(input.startIndex..., in: input)

    // Colon format
    if let colonMatch = colonDurationPattern.firstMatch(in: input, range: nsRange) {
        let h = Range(colonMatch.range(at: 1), in: input).flatMap { Int(input[$0]) } ?? 0
        let m = Range(colonMatch.range(at: 2), in: input).flatMap { Int(input[$0]) } ?? 0
        let s: Int
        if colonMatch.range(at: 3).location != NSNotFound,
           let sRange = Range(colonMatch.range(at: 3), in: input) {
            s = Int(input[sRange]) ?? 0
        } else { s = 0 }
        let total = h * 3600 + m * 60 + s
        if total > 0 { return total }
    }

    // Component format
    let matches = durationComponentPattern.matches(in: input, range: nsRange)
    guard !matches.isEmpty else { return nil }

    var totalSeconds = 0
    for match in matches {
        guard let numRange = Range(match.range(at: 1), in: input),
              let unitRange = Range(match.range(at: 2), in: input),
              let num = Int(input[numRange]) else { continue }
        let unit = String(input[unitRange]).lowercased()
        if unit.hasPrefix("h") { totalSeconds += num * 3600 }
        else if unit.hasPrefix("m") { totalSeconds += num * 60 }
        else if unit.hasPrefix("s") { totalSeconds += num }
    }
    return totalSeconds > 0 ? totalSeconds : nil
}

group("8. Compound Duration Parsing")
assertEqual(parseCompoundDuration("5 minutes"), 300, "5 minutes → 300s")
assertEqual(parseCompoundDuration("1 hour"), 3600, "1 hour → 3600s")
assertEqual(parseCompoundDuration("30 seconds"), 30, "30 seconds → 30s")
assertEqual(parseCompoundDuration("1 hour 30 minutes"), 5400, "1 hour 30 minutes → 5400s")
assertEqual(parseCompoundDuration("2 hours 15 minutes and 30 seconds"), 8130, "2h 15m 30s → 8130s")
assertEqual(parseCompoundDuration("90 minutes"), 5400, "90 minutes → 5400s")
assertEqual(parseCompoundDuration("timer for 2h15m"), 8100, "2h15m → 8100s")
assertEqual(parseCompoundDuration("set a timer for 45s"), 45, "45s → 45s")
assertEqual(parseCompoundDuration("timer for 1:30"), 5400, "1:30 → 5400s (1h 30m)")
assertEqual(parseCompoundDuration("timer 0:05:00"), 300, "0:05:00 → 300s")
assertEqual(parseCompoundDuration("10 mins"), 600, "10 mins → 600s")
assertEqual(parseCompoundDuration("3 hrs"), 10800, "3 hrs → 10800s")
assertEqual(parseCompoundDuration("1 hour and 30 minutes"), 5400, "1 hour and 30 minutes → 5400s")
assertEqual(parseCompoundDuration("no duration here"), nil, "no duration → nil")

// ═══════════════════════════════════════════════════════════════
// MARK: - 9. Web Platform Resolution
// ═══════════════════════════════════════════════════════════════

let siteShortcuts: [String: String] = [
    "twitter": "https://x.com", "x": "https://x.com",
    "gmail": "https://mail.google.com",
    "hacker news": "https://news.ycombinator.com",
    "hackernews": "https://news.ycombinator.com",
    "hn": "https://news.ycombinator.com",
    "wikipedia": "https://en.wikipedia.org",
    "spotify": "https://open.spotify.com",
    "chatgpt": "https://chat.openai.com",
    "claude": "https://claude.ai",
    "notion": "https://www.notion.so",
    "discord": "https://discord.com/app",
    "slack": "https://app.slack.com",
    "twitch": "https://www.twitch.tv",
    "npm": "https://www.npmjs.com",
]

let nonSiteWords: Set<String> = [
    "the", "and", "for", "but", "not", "with", "from", "that", "this", "what",
    "open", "close", "find", "search", "play", "stop", "start", "move", "show",
    "file", "folder", "window", "tab", "page", "screen", "volume", "brightness",
    "music", "song", "timer", "alarm", "note", "all", "new", "current", "my", "app",
]

func resolveURL(_ target: String) -> String? {
    let clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, !clean.contains(" ") else { return nil }
    if clean.hasPrefix("http://") || clean.hasPrefix("https://") { return clean }
    if clean.contains(".") { return "https://\(clean)" }
    if let url = siteShortcuts[clean.lowercased()] { return url }
    let lower = clean.lowercased()
    if lower.count >= 3 && lower.allSatisfy({ $0.isLetter }) && !nonSiteWords.contains(lower) {
        return "https://www.\(lower).com"
    }
    return nil
}

func normalizePlatform(_ raw: String) -> String {
    var name = raw.lowercased()
    for prefix in ["www.", "en.", "web.", "app.", "m."] {
        if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
    }
    for suffix in [".com", ".org", ".net", ".io", ".tv", ".co", ".ai", ".so", ".gg", ".app"] {
        if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
    }
    return name
}

group("9. Web Platform Resolution")
// resolveURL
assertEqual(resolveURL("youtube"), "https://www.youtube.com", "youtube → youtube.com (dynamic)")
assertEqual(resolveURL("reddit"), "https://www.reddit.com", "reddit → reddit.com (dynamic)")
assertEqual(resolveURL("shopify"), "https://www.shopify.com", "shopify → shopify.com (dynamic, not hardcoded)")
assertEqual(resolveURL("zillow"), "https://www.zillow.com", "zillow → zillow.com (dynamic)")
assertEqual(resolveURL("twitter"), "https://x.com", "twitter → x.com (shortcut)")
assertEqual(resolveURL("hn"), "https://news.ycombinator.com", "hn → news.ycombinator.com (shortcut)")
assertEqual(resolveURL("claude"), "https://claude.ai", "claude → claude.ai (shortcut)")
assertEqual(resolveURL("notion"), "https://www.notion.so", "notion → notion.so (shortcut)")
assertEqual(resolveURL("youtube.com"), "https://youtube.com", "youtube.com → https://youtube.com")
assertEqual(resolveURL("https://example.com"), "https://example.com", "full URL unchanged")
assertEqual(resolveURL("open"), nil, "NOT: 'open' (common word)")
assertEqual(resolveURL("the"), nil, "NOT: 'the' (common word)")
assertEqual(resolveURL("my file"), nil, "NOT: 'my file' (contains space)")
assertEqual(resolveURL("hi"), nil, "NOT: 'hi' (too short)")

// normalizePlatform
assertEqual(normalizePlatform("youtube.com"), "youtube", "youtube.com → youtube")
assertEqual(normalizePlatform("www.reddit.com"), "reddit", "www.reddit.com → reddit")
assertEqual(normalizePlatform("en.wikipedia.org"), "wikipedia", "en.wikipedia.org → wikipedia")
assertEqual(normalizePlatform("app.slack.com"), "slack", "app.slack.com → slack")
assertEqual(normalizePlatform("twitch.tv"), "twitch", "twitch.tv → twitch")
assertEqual(normalizePlatform("crates.io"), "crates", "crates.io → crates")
assertEqual(normalizePlatform("bsky.app"), "bsky", "bsky.app → bsky")
assertEqual(normalizePlatform("youtube"), "youtube", "youtube unchanged")

// ═══════════════════════════════════════════════════════════════
// MARK: - 10. App Name Aliases
// ═══════════════════════════════════════════════════════════════

let appAliases: [String: String] = [
    "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
    "chrome": "Google Chrome", "word": "Microsoft Word", "excel": "Microsoft Excel",
    "powerpoint": "Microsoft PowerPoint", "ppt": "Microsoft PowerPoint",
    "outlook": "Microsoft Outlook", "teams": "Microsoft Teams",
    "iterm": "iTerm", "iterm2": "iTerm",
    "system settings": "System Settings", "system preferences": "System Settings",
    "app store": "App Store",
    "activity monitor": "Activity Monitor",
    "text edit": "TextEdit", "textedit": "TextEdit",
    "face time": "FaceTime", "facetime": "FaceTime",
]

func resolveAppAlias(_ name: String) -> String {
    return appAliases[name.lowercased()] ?? name
}

group("10. App Name Aliases")
assertEqual(resolveAppAlias("chrome"), "Google Chrome", "chrome → Google Chrome")
assertEqual(resolveAppAlias("vs code"), "Visual Studio Code", "vs code → Visual Studio Code")
assertEqual(resolveAppAlias("vscode"), "Visual Studio Code", "vscode → Visual Studio Code")
assertEqual(resolveAppAlias("code"), "Visual Studio Code", "code → Visual Studio Code")
assertEqual(resolveAppAlias("word"), "Microsoft Word", "word → Microsoft Word")
assertEqual(resolveAppAlias("excel"), "Microsoft Excel", "excel → Microsoft Excel")
assertEqual(resolveAppAlias("ppt"), "Microsoft PowerPoint", "ppt → Microsoft PowerPoint")
assertEqual(resolveAppAlias("teams"), "Microsoft Teams", "teams → Microsoft Teams")
assertEqual(resolveAppAlias("iterm"), "iTerm", "iterm → iTerm")
assertEqual(resolveAppAlias("facetime"), "FaceTime", "facetime → FaceTime")
assertEqual(resolveAppAlias("Safari"), "Safari", "Safari unchanged (no alias needed)")
assertEqual(resolveAppAlias("Xcode"), "Xcode", "Xcode unchanged")

// ═══════════════════════════════════════════════════════════════
// MARK: - Results
// ═══════════════════════════════════════════════════════════════

print("\n" + String(repeating: "═", count: 50))
if failed == 0 {
    print("\u{001B}[32m\u{001B}[1mALL \(passed) TESTS PASSED\u{001B}[0m")
} else {
    print("\u{001B}[31m\u{001B}[1m\(failed) FAILED\u{001B}[0m, \(passed) passed")
}
print(String(repeating: "═", count: 50))

exit(failed > 0 ? 1 : 0)
