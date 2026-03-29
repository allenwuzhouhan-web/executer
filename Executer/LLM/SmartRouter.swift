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
        (
            { $0.hasPrefix("translate") || $0.contains("translate this") ||
              $0.contains("to spanish") || $0.contains("to french") || $0.contains("to chinese") ||
              $0.contains("to japanese") || $0.contains("to german") || $0.contains("to korean") ||
              $0.contains("to portuguese") || $0.contains("to italian") || $0.contains("to arabic") ||
              $0.contains("in spanish") || $0.contains("in french") || $0.contains("in chinese") },
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
