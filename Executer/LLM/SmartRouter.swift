import Foundation

/// Routes single-tool queries to a minimal LLM call, bypassing the full AgentLoop.
/// Sits between LocalCommandRouter (zero LLM) and AgentLoop (full multi-turn).
/// For queries that need the LLM to formulate arguments but always result in 1 tool call.
class SmartRouter {
    static let shared = SmartRouter()
    private init() {}

    struct SingleToolMatch {
        let toolName: String?  // nil = LLM answers directly (no tool call)
        let minimalPrompt: String
        let maxTokens: Int
    }

    /// Patterns that map to single-tool shortcuts.
    /// Each entry: (predicate on lowercased command, tool name or nil, focused prompt, max tokens)
    private let patterns: [(predicate: (String) -> Bool, toolName: String?, prompt: String, maxTokens: Int)] = [
        // Weather
        (
            { $0.contains("weather") || $0.contains("temperature") || $0.contains("forecast") },
            "get_weather",
            "You are a weather assistant. Call get_weather with the appropriate parameters based on the user's location or query. Respond with a 1-sentence weather summary.",
            512
        ),
        // Translation (LLM-only, no tool needed)
        // Dynamic: matches "translate X to [any language]", "say X in [any language]",
        // "how do you say X in [any language]", "X in [any language]" (if ends with " in [word]")
        (
            { cmd in
                if cmd.hasPrefix("translate") || cmd.contains("translate this") { return true }
                if cmd.hasPrefix("how do you say ") || cmd.hasPrefix("how to say ") { return true }
                // "to [language]" / "in [language]" — match dynamically instead of listing languages
                // Look for " to " or " in " followed by a single word (the language)
                for prep in [" to ", " in "] {
                    if let range = cmd.range(of: prep, options: .backwards) {
                        let after = cmd[range.upperBound...].trimmingCharacters(in: .whitespaces)
                        // Language name: 1-2 words, all letters (e.g., "spanish", "mandarin chinese")
                        let words = after.split(separator: " ")
                        if words.count <= 2 && words.allSatisfy({ $0.allSatisfy({ $0.isLetter }) }) {
                            // Avoid false positives: "to" must follow translatable content, not actions
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
            },
            nil,
            "Translate the text as requested. Output ONLY the translation, nothing else. No preamble.",
            1024
        ),
        // Timer with natural language duration
        (
            { ($0.contains("timer") || $0.hasPrefix("remind me in")) && !$0.contains("list") && !$0.contains("show") },
            "set_timer",
            "Parse the user's request and call set_timer with duration_seconds and label. Convert natural language durations (e.g., '5 minutes' = 300, '1 hour' = 3600).",
            256
        ),
        // Notification / announce
        (
            { $0.hasPrefix("notify ") || $0.hasPrefix("notification ") || $0.hasPrefix("alert ") },
            "show_notification",
            "Call show_notification with an appropriate title and body based on the user's request.",
            256
        ),
        // Meeting prep
        (
            { ($0.contains("prep") || $0.contains("prepare")) && ($0.contains("meeting") || $0.contains("call")) },
            "prepare_meeting",
            "Call prepare_meeting to gather all relevant context for the upcoming meeting. Present the prep brief clearly.",
            1024
        ),
        // Meeting status
        (
            { $0.contains("meeting") && ($0.contains("status") || $0.hasPrefix("am i in") || $0.contains("in a meeting") || $0.contains("next meeting") || $0.contains("what meeting")) },
            "meeting_status",
            "Call meeting_status to check the user's current meeting state.",
            512
        ),
        // Calendar query
        (
            { ($0.contains("calendar") || $0.contains("meeting") || $0.contains("events")) &&
              ($0.contains("today") || $0.contains("tomorrow") || $0.contains("this week") || $0.contains("schedule")) &&
              !$0.contains("create") && !$0.contains("add") },
            "query_calendar_events",
            "Call query_calendar_events with the appropriate date range. Present events as a clean bullet list with times.",
            512
        ),
        // System info
        (
            { $0 == "system info" || $0 == "system information" || $0.contains("about this mac") ||
              ($0.contains("system") && $0.contains("info")) },
            "get_system_info",
            "Call get_system_info and present the results clearly.",
            512
        ),
        // Volume query
        (
            { ($0.contains("what") && $0.contains("volume")) || $0 == "volume?" || $0 == "volume" },
            "get_volume",
            "Call get_volume and report the current volume level as a percentage.",
            256
        ),
        // Brightness query
        (
            { ($0.contains("what") && $0.contains("brightness")) || $0 == "brightness?" || $0 == "brightness" },
            "get_brightness",
            "Call get_brightness and report the current brightness level as a percentage.",
            256
        ),
        // Current time (LLM-only — time is in system context)
        (
            { $0.contains("what time") || $0 == "time" || $0 == "what's the time" || $0 == "current time" },
            nil,
            "Tell the user the current time based on the system context provided. Be concise: just the time.",
            128
        ),
        // Music status / now playing
        (
            { ($0.contains("what") && $0.contains("playing")) || $0 == "now playing" ||
              $0.contains("current song") || $0.contains("what song") },
            "music_get_current",
            "Call music_get_current and tell the user what's currently playing in one sentence.",
            256
        ),
        // Reminders query
        (
            { ($0.contains("reminders") || $0.contains("my reminders")) &&
              !$0.contains("create") && !$0.contains("add") },
            "query_reminders",
            "Call query_reminders to list the user's reminders. Present as a clean bullet list.",
            512
        ),
        // Dictionary / define
        (
            { $0.hasPrefix("define ") || ($0.hasPrefix("what does ") && $0.hasSuffix(" mean")) ||
              $0.hasPrefix("meaning of ") },
            "dictionary_lookup",
            "Call dictionary_lookup for the word the user wants defined. Present the definition concisely.",
            512
        ),
        // Spell check
        (
            { $0.hasPrefix("spell ") || $0.contains("how do you spell") || $0.contains("spelling of") },
            "spell_check",
            "Call spell_check for the word. Report whether it's correct and suggest corrections if not.",
            256
        ),
        // Running apps
        (
            { $0 == "what apps are running" || $0 == "running apps" || $0.contains("list running") ||
              $0 == "what's running" || $0 == "whats running" },
            "list_running_apps",
            "Call list_running_apps and present a clean list of currently running applications.",
            512
        ),
        // Dark mode query
        (
            { ($0.contains("is dark mode") && $0.contains("?")) || $0 == "dark mode?" ||
              ($0.contains("dark mode") && $0.contains("on")) },
            "get_dark_mode",
            "Call get_dark_mode and tell the user whether dark mode is on or off.",
            128
        ),
        // Academic paper search (Semantic Scholar)
        (
            { ($0.contains("paper") && ($0.contains("search") || $0.contains("find") || $0.contains("about"))) ||
              $0.hasPrefix("scholar ") || $0.contains("semantic scholar") ||
              ($0.contains("academic") && $0.contains("research")) },
            "semantic_scholar_search",
            "Search for academic papers using semantic_scholar_search. Present results as a numbered list with titles, authors, year, and citation count.",
            1024
        ),
        // News
        (
            { $0.contains("in the news") || $0.contains("latest news") || $0.contains("news today") ||
              $0.contains("top headlines") || $0.contains("news about") ||
              $0 == "news" || $0 == "whats in the news" || $0 == "what's in the news" },
            "fetch_news",
            "Call fetch_news with appropriate parameters. If a topic is mentioned, pass it as the query. Present headlines as a numbered list with source names.",
            1024
        ),
        // Email search (NOT send/compose/write/draft)
        (
            { cmd in
                let isSearch = cmd.contains("check my email") || cmd.contains("any new emails") ||
                    cmd.contains("emails from") || cmd.contains("emails about") ||
                    cmd.contains("search mail") || cmd.contains("search email") ||
                    cmd.contains("my emails") || cmd.contains("my inbox") ||
                    (cmd.contains("email") && !cmd.contains("send email") && !cmd.contains("compose") &&
                     !cmd.contains("write email") && !cmd.contains("draft email"))
                let isCompose = cmd.contains("send ") || cmd.contains("compose") ||
                    cmd.contains("write email") || cmd.contains("draft email")
                return isSearch && !isCompose
            },
            "search_mail",
            "Call search_mail with appropriate parameters based on the user's query. Present results as a clean list with sender, subject, and date.",
            1024
        ),
        // Clipboard history
        (
            { $0.contains("clipboard history") || $0.contains("recent copies") ||
              $0.contains("what did i copy before") || $0.contains("show clipboard history") ||
              $0.contains("my recent clips") || $0.contains("clipboard entries") },
            "get_clipboard_history",
            "Call get_clipboard_history and present the recent clipboard entries as a numbered list.",
            512
        ),
        // File finding with natural language (catches what local router misses)
        (
            { cmd in
                // Skip if already handled by local router: "find files" or "find " + single word without "my/the"
                if cmd.hasPrefix("find files") { return false }
                if cmd.hasPrefix("find ") && !cmd.contains("my") && !cmd.contains("the") {
                    let afterFind = cmd.dropFirst(5)
                    if !afterFind.contains(" ") { return false }
                }
                return cmd.contains("find my") || cmd.contains("where did i put") ||
                    cmd.hasPrefix("locate ") ||
                    (cmd.contains("find") && (cmd.contains("file") || cmd.contains("document") ||
                     cmd.contains("photo") || cmd.contains("pdf") || cmd.contains("spreadsheet")))
            },
            "find_files",
            "Call find_files to search for the file the user is looking for. If a file type is implied (e.g., 'document' → .docx/.doc, 'spreadsheet' → .xlsx, 'photo' → .jpg/.png), narrow the search. Search ~/Documents, ~/Desktop, ~/Downloads by default.",
            512
        ),
        // Calendar creation (NOT queries like "what's on my calendar")
        (
            { cmd in
                return (cmd.contains("schedule") && (cmd.contains("meeting") || cmd.contains("event") || cmd.contains("call"))) ||
                    (cmd.contains("create") && cmd.contains("event")) ||
                    (cmd.contains("add") && cmd.contains("calendar")) ||
                    cmd.hasPrefix("new event") || cmd.hasPrefix("new meeting")
            },
            "create_calendar_event",
            "Call create_calendar_event with the event details from the user's request. Parse dates, times, and duration naturally (e.g., 'tomorrow at 3pm for 1 hour'). Include the current date/time for reference.",
            512
        ),
        // Bluetooth connect
        (
            { cmd in
                return (cmd.contains("connect") && (cmd.contains("airpods") || cmd.contains("headphones") ||
                    cmd.contains("speaker") || cmd.contains("keyboard") || cmd.contains("mouse") ||
                    cmd.contains("bluetooth"))) ||
                    cmd.hasPrefix("connect to ") || cmd.hasPrefix("pair ")
            },
            "connect_bluetooth_device",
            "Call connect_bluetooth_device with the device name the user wants to connect to. Common device names: AirPods, AirPods Pro, AirPods Max.",
            256
        ),
        // Open file with specific app
        (
            { cmd in
                let startsRight = cmd.hasPrefix("open ") || cmd.hasPrefix("edit ")
                let hasPreposition = cmd.contains(" with ") || cmd.contains(" in ") || cmd.contains(" using ")
                let looksLikeFile = cmd.contains("/") || cmd.contains(".") || cmd.contains("~") ||
                    cmd.contains("desktop") || cmd.contains("downloads") || cmd.contains("documents")
                return startsRight && hasPreposition && looksLikeFile
            },
            "open_file_with_app",
            "Call open_file_with_app with the file path and application name. Resolve relative paths and shortcuts (desktop → ~/Desktop, downloads → ~/Downloads).",
            256
        ),
        // Quick math/conversion too complex for local calc
        (
            { cmd in
                let isConversion = cmd.hasPrefix("convert ") || cmd.hasPrefix("how many ")
                let isPercentage = cmd.hasPrefix("what is ") && cmd.contains("%") && cmd.contains("of")
                let isWebRelated = cmd.contains(".com") || cmd.contains(".org") || cmd.contains(".net") ||
                    cmd.contains("http") || cmd.contains("www")
                return (isConversion || isPercentage) && !isWebRelated
            },
            nil,
            "Calculate or convert as requested. Show the result first, then the formula/method briefly. Be concise.",
            256
        ),
        // Summarize what's on screen
        (
            { $0.hasPrefix("summarize") || $0 == "tldr" || $0.contains("give me a summary") ||
              $0.contains("summarize this") || $0.contains("summarize the page") ||
              $0.contains("summarize what") },
            "read_screen",
            "Call read_screen to capture what's currently visible, then provide a concise summary (3-5 bullet points). Focus on the key information.",
            1024
        ),
        // Read/OCR screen
        (
            { $0.contains("what's on my screen") || $0.contains("whats on my screen") ||
              $0.contains("read the screen") || $0.contains("read what's on screen") ||
              $0.contains("what do you see") || $0.contains("what am i looking at") ||
              $0.contains("read my screen") },
            "read_screen",
            "Call read_screen and describe what's visible. Be specific about app names, text content, and notable UI elements. Keep it brief.",
            1024
        ),
        // Knowledge / factual queries (LLM-only, no tool — must be LAST to avoid shadowing)
        (
            { cmd in
                // Exclude system/action queries that should go to other handlers
                let actionPrefixes = ["open ", "launch ", "play ", "close ", "quit ", "set ", "turn ",
                                      "toggle ", "switch ", "move ", "delete ", "create ", "send ",
                                      "search ", "find file", "run ", "fullscreen ", "click ",
                                      "type ", "press ", "maximize ", "minimize ", "resize ",
                                      "scroll ", "drag ", "hotkey "]
                if actionPrefixes.contains(where: { cmd.hasPrefix($0) }) { return false }
                let actionWords = ["my battery", "my volume", "my brightness", "my wifi",
                                   "this mac", "current app", "running apps", "dark mode",
                                   "apps open", "apps running", "what apps", "which apps",
                                   "open apps", "active apps", "frontmost", "what app is",
                                   "working on", "my goals", "my patterns", "autonomy",
                                   "learned from", "my sessions", "day plan"]
                if actionWords.contains(where: { cmd.contains($0) }) { return false }
                // UI action keywords anywhere in command → must go to AgentLoop
                let uiActionKeywords = ["click", "fullscreen", "maximize", "minimize", "resize",
                                        "type text", "press key", "hotkey", "scroll", "drag",
                                        "move cursor", "and then", "after that", "and click",
                                        "then click", "then type", "then press", "and open",
                                        "and close", "and play", "and search"]
                if uiActionKeywords.contains(where: { cmd.contains($0) }) { return false }

                // Knowledge triggers
                let prefixes = ["what is ", "what are ", "what was ", "what were ",
                                "who is ", "who was ", "who are ", "who were ",
                                "how does ", "how do ", "how is ", "how are ",
                                "explain ", "describe ", "why is ", "why do ", "why does ",
                                "when was ", "when did ", "when is ",
                                "where is ", "where was ", "where are "]
                let suffixes = [" formula", " equation", " theorem", " law",
                                " principle", " definition", " constant"]
                let keywords = ["formula", "equation", "theorem", "derivative", "integral",
                                "proof", "definition", "half angle", "double angle", "pythagorean",
                                "quadratic", "binomial", "taylor", "capital of", "population of",
                                "speed of light", "boiling point", "meaning of", "history of"]

                if prefixes.contains(where: { cmd.hasPrefix($0) }) { return true }
                if suffixes.contains(where: { cmd.hasSuffix($0) }) { return true }
                if keywords.contains(where: { cmd.contains($0) }) { return true }
                // Short PURE KNOWLEDGE questions only — must start with a knowledge prefix
                // Do NOT catch-all short questions — that kills tool-needing queries like
                // "whats on news?", "what apps open?", "what am I working on?"
                return false
            },
            nil,
            """
            Answer the user's question directly and concisely.
            For math: use Unicode symbols (sin(θ/2) = ±√((1−cos θ)/2), x², ∑, ∫, π, ∞, ≤, ≥, ≠).
            Give the answer first, then a brief explanation if needed. Under 150 words. No preamble.
            """,
            512
        ),
    ]

    // Cached formatter for injecting current date into prompts
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        return f
    }()

    /// Returns a SingleToolMatch if this query can be shortcut, nil otherwise.
    func trySingleToolRoute(_ command: String) -> SingleToolMatch? {
        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Self.dateFormatter.string(from: Date())

        for entry in patterns {
            if entry.predicate(lower) {
                // Inject current date/time so the LLM knows what "today" means
                let prompt = "Current date/time: \(now)\n\n\(entry.prompt)"
                return SingleToolMatch(
                    toolName: entry.toolName,
                    minimalPrompt: prompt,
                    maxTokens: entry.maxTokens
                )
            }
        }

        return nil
    }
}
