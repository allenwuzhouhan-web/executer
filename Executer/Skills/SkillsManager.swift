import Foundation

/// Manages compound skills — reusable multi-step workflows the LLM can follow.
/// Default skills are built-in; user-created skills persist to disk.
class SkillsManager {
    static let shared = SkillsManager()

    struct Skill: Codable {
        let name: String
        let description: String
        let exampleTriggers: [String]
        let steps: [String]
    }

    private(set) var skills: [Skill] = []
    /// Cached prompt section string, invalidated when skills change
    private var cachedPromptSection: String?

    private let userSkillsURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user_skills.json")
    }()

    private init() {
        skills = Self.defaultSkills + loadUserSkills()
        print("[Skills] Loaded \(skills.count) skills (\(Self.defaultSkills.count) built-in, \(skills.count - Self.defaultSkills.count) user)")
    }

    // MARK: - Add / Remove

    func addSkill(_ skill: Skill) {
        // Replace if same name exists (in user skills only)
        skills.removeAll { $0.name == skill.name }
        skills.append(skill)
        cachedPromptSection = nil
        saveUserSkills()
        print("[Skills] Added skill: \(skill.name)")
    }

    func removeSkill(named name: String) -> Bool {
        // Can't remove built-in skills
        guard !Self.defaultSkills.contains(where: { $0.name == name }) else { return false }
        let before = skills.count
        skills.removeAll { $0.name == name }
        if skills.count < before {
            cachedPromptSection = nil
            saveUserSkills()
            return true
        }
        return false
    }

    // MARK: - Prompt Injection

    /// Formats all skills as a prompt section for the LLM system message.
    func promptSection() -> String {
        if let cached = cachedPromptSection { return cached }
        guard !skills.isEmpty else { return "" }

        var lines = [
            "",
            "## Compound Skills",
            "",
            "When a user's request matches one of these skills, follow the steps using your available tools.",
            "When a step says to call multiple tools, do so in a single response (parallel tool calls).",
            ""
        ]

        for skill in skills {
            lines.append("### \(skill.name)")
            lines.append(skill.description)
            if !skill.exampleTriggers.isEmpty {
                lines.append("Triggers: \(skill.exampleTriggers.map { "\"\($0)\"" }.joined(separator: ", "))")
            }
            lines.append("Steps:")
            for (i, step) in skill.steps.enumerated() {
                lines.append("\(i + 1). \(step)")
            }
            lines.append("")
        }

        let result = lines.joined(separator: "\n")
        cachedPromptSection = result
        return result
    }

    // MARK: - Persistence

    private func loadUserSkills() -> [Skill] {
        guard FileManager.default.fileExists(atPath: userSkillsURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: userSkillsURL)
            return try JSONDecoder().decode([Skill].self, from: data)
        } catch {
            print("[Skills] Failed to load user skills: \(error)")
            return []
        }
    }

    private func saveUserSkills() {
        let builtInNames = Set(Self.defaultSkills.map(\.name))
        let userOnly = skills.filter { !builtInNames.contains($0.name) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(userOnly)
            try data.write(to: userSkillsURL, options: .atomic)
        } catch {
            print("[Skills] Failed to save user skills: \(error)")
        }
    }

    // MARK: - Default Skills

    private static let defaultSkills: [Skill] = [
        // MARK: Research (primary use case)
        Skill(
            name: "deep_research",
            description: "Curated link collection for deep exploration. Use when the user asks to research, investigate, explain, or deeply explore a topic. Returns 8-12 diverse, credible URLs with one-sentence summaries grouped by subtopic — NOT a full written report.",
            exampleTriggers: ["research quantum computing", "deep dive into Swift concurrency", "investigate AI regulation", "explain how transformers work", "what's the latest on fusion energy"],
            steps: [
                "Tell the user: 'Researching [topic] — finding the best sources...'",
                "Plan 8-12 URLs covering diverse angles: Wikipedia overview (https://en.wikipedia.org/wiki/Topic_Name), 2-3 authoritative sources (.gov, .edu, official docs), 2-3 recent news or analysis articles, 1-2 specialized or niche sources, and 1-2 tutorials or explainers. Aim for breadth — cover different subtopics, not multiple articles saying the same thing.",
                "Call `fetch_url_content` for ALL planned URLs in a SINGLE response (parallel tool calls). Use max_length=3000 for each — you only need enough to write a one-sentence summary. You MUST actually fetch these URLs.",
                "Read all results. If any URL failed or returned thin content, fetch 2-3 replacement URLs to maintain at least 8 good sources.",
                """
Present the results as a CURATED LINK COLLECTION — not a report. Format:

# [Topic]: Key Sources

Group the links into 3-5 subtopic sections. For each source:

### [Subtopic Name]
- **[Source Name]** — One sentence summarizing what this source covers and why it's useful.
  [full URL]
- **[Source Name]** — One sentence summary.
  [full URL]

(repeat for each subtopic section)

RULES:
- Each source gets exactly ONE sentence — no paragraphs, no bullet sub-points.
- Every source MUST have its full clickable URL on its own line.
- Do NOT write analysis, synthesis, or opinions. Let the sources speak.
- 8-12 sources total across all sections.
""",
                "Copy the full link collection to clipboard using `set_clipboard_text`.",
                "Tell the user: 'Found [N] sources on [topic] — copied to clipboard and opened in TextEdit. Click through the links to explore.'"
            ]
        ),
        Skill(
            name: "light_research",
            description: "Quick factual lookup: fetch 1-2 sources to answer a straightforward question. Use when the user asks a factual question, wants a quick answer, or the question can be answered from one good source.",
            exampleTriggers: ["what is the capital of France", "how tall is the Eiffel Tower", "when was Python created", "what's the population of Tokyo", "who invented the internet", "what does CRISPR stand for"],
            steps: [
                "Tell the user: 'Quick lookup...' so they know what mode you're in.",
                "Construct 1-2 URLs likely to contain the answer — prefer Wikipedia or an official source. Call `fetch_url_content` with max_length=4000. You MUST fetch at least one URL — never answer from memory alone.",
                "Extract the specific answer. Respond with a direct, concise answer — 1-3 sentences max. No filler.",
                "MANDATORY — End with: 'Source: [Page Title](https://the.actual.url)' for every URL you fetched. No source = failed task."
            ]
        ),
        Skill(
            name: "compare",
            description: "Compare two or more things side-by-side by fetching information about each. Use when the user asks to compare, contrast, or decide between options.",
            exampleTriggers: ["compare React vs Vue", "compare M3 vs M4 chip", "differences between Python and Rust", "should I use PostgreSQL or MongoDB"],
            steps: [
                "Tell the user: 'Comparing [X] vs [Y]...'",
                "For each item, construct one authoritative URL (Wikipedia, official docs, or a known comparison site). Call `fetch_url_content` for ALL items in a SINGLE response (parallel tool calls). You MUST fetch real URLs.",
                "Extract comparable attributes for each: performance, features, use cases, pros/cons, pricing if relevant.",
                "Present a structured comparison with a brief verdict or recommendation.",
                "MANDATORY — End with a 'Sources:' section listing every URL you fetched as '[Title](url)'. Copy full comparison (including sources) to clipboard using `set_clipboard_text`."
            ]
        ),
        Skill(
            name: "summarize_url",
            description: "Fetch any URL or read the current Safari/Chrome page and provide a concise summary.",
            exampleTriggers: ["summarize this page", "summarize https://example.com", "tldr this article", "what does this page say"],
            steps: [
                "If the user provided a URL, use `fetch_url_content` with max_length=10000. If no URL, use `read_safari_page` with max_length=10000 to read the current tab.",
                "Provide: one-sentence summary, then 3-5 bullet points of key information.",
                "If the user asked to remember it, use `save_memory` with category 'note' to save a one-line summary."
            ]
        ),

        // MARK: System / Utility skills
        Skill(
            name: "organize_desktop",
            description: "Sort files on the Desktop into categorized subfolders by file type.",
            exampleTriggers: ["sort my desktop", "clean up desktop", "organize desktop files"],
            steps: [
                "Use `run_shell_command` with `ls ~/Desktop` to list all files.",
                "Categorize by extension: Documents (.pdf, .doc, .txt), Images (.png, .jpg, .heic), Videos (.mp4, .mov), Archives (.zip, .dmg), Code (.swift, .py, .js), Other.",
                "Use `create_folder` for each category inside ~/Desktop.",
                "Use `move_file` for each file to its category. Skip folders.",
                "Report summary of what was moved."
            ]
        ),
        Skill(
            name: "play_song",
            description: "Find and play a song in Apple Music. Searches the full streaming catalog, not just your library.",
            exampleTriggers: ["play lose my mind by doja cat", "play bohemian rhapsody", "play some jazz", "put on the weeknd"],
            steps: [
                "Use `music_play_song` with the full query (include song name and artist if given).",
                "If the user wants a specific volume, also use `music_set_volume`.",
                "Confirm what's playing with a short response."
            ]
        ),
        Skill(
            name: "cleanup_downloads",
            description: "Find large or old files in Downloads and offer to trash them.",
            exampleTriggers: ["clean up downloads", "free up space in downloads"],
            steps: [
                "Use `run_shell_command` to find files >50MB and files older than 30 days in ~/Downloads.",
                "List what you found with sizes and ages.",
                "For confirmed files, use `trash_file`. Report space reclaimed."
            ]
        ),

        // MARK: Super Agent skills
        Skill(
            name: "morning_briefing",
            description: "Get a morning briefing: current weather, today's calendar events, and a quick status check.",
            exampleTriggers: ["morning briefing", "good morning", "what's on today", "brief me", "daily summary", "what's my day look like"],
            steps: [
                "Tell the user: 'Getting your morning briefing...'",
                "In parallel: (1) Use `get_weather` with include_forecast=true for current conditions and today's forecast. (2) Use `query_calendar_events` to get today's events.",
                "Present a clean briefing: weather line, then today's events as a bullet list. Keep it concise — this should feel like a quick glance, not a research report."
            ]
        ),
        Skill(
            name: "compose_email",
            description: "Draft and open an email in Mail.app, ready to review and send.",
            exampleTriggers: ["send an email to", "compose email", "write an email", "email about", "draft a message to", "email john about"],
            steps: [
                "Extract recipient, subject, and body from the user's request. Infer a sensible subject line if not provided.",
                "Use `run_shell_command` with an osascript command to create the email in Mail: osascript -e 'tell application \"Mail\" to make new outgoing message with properties {subject:\"SUBJECT\", content:\"BODY\", visible:true}' — also add recipients with: tell newMsg to make new to recipient with properties {address:\"EMAIL\"}.",
                "Use `launch_app` with \"Mail\" to bring it to the foreground.",
                "Report: 'Email drafted and opened in Mail — review and hit Send when ready.'"
            ]
        ),
        Skill(
            name: "system_health",
            description: "Run a quick system health check: disk space, memory usage, CPU load, and battery status.",
            exampleTriggers: ["system health", "how's my mac doing", "check system status", "disk space", "memory usage", "system diagnostics", "battery health"],
            steps: [
                "Tell the user: 'Running system health check...'",
                "Use `run_shell_command` with a compound command: df -h / && echo '---' && vm_stat | head -5 && echo '---' && uptime && echo '---' && pmset -g batt && echo '---' && sysctl -n machdep.cpu.brand_string",
                "Parse the output and present a clean summary: Disk (used/available), Memory (approximate free/used from vm_stat pages × 16KB), CPU (model + load averages from uptime), Battery (% + charging status), Uptime. Flag anything concerning (disk >90%, high load, low battery)."
            ]
        ),
        Skill(
            name: "focus_session",
            description: "Start a focus session: enable Do Not Disturb, quit distracting apps, and set a timer.",
            exampleTriggers: ["focus mode", "start focus session", "help me focus", "deep work mode", "no distractions", "pomodoro"],
            steps: [
                "Tell the user: 'Setting up focus session...'",
                "Use `toggle_do_not_disturb` to turn on DND.",
                "Use `quit_app` for common distracting apps — try each silently (don't error if not running): Messages, Slack, Discord, Twitter, Reddit, Instagram. Call multiple `quit_app` in parallel.",
                "If the user specified a duration, use `set_timer` with that duration and label 'Focus Session Over'. Default to 25 minutes (Pomodoro) if no duration given.",
                "Confirm: 'Focus session started. DND on, distractions closed. Timer set for X minutes.'"
            ]
        ),
        Skill(
            name: "quick_capture",
            description: "Capture a quick thought or the current clipboard content into Notes.app with a timestamp.",
            exampleTriggers: ["quick note", "capture this", "save to notes", "note this down", "jot down", "save what I copied"],
            steps: [
                "If the user provided specific text, use that. If they said 'capture this', 'save clipboard', or similar, use `get_clipboard_text` to get clipboard contents.",
                "Use `create_note` with a title like 'Capture — YYYY-MM-DD HH:MM' (use current date/time from the system context) and the text as the body.",
                "Confirm: 'Saved to Notes: [first 50 chars of content]...'"
            ]
        ),
        Skill(
            name: "download_file",
            description: "Download a file from a URL to the Downloads folder and optionally open it.",
            exampleTriggers: ["download this file", "download from", "save this url", "download that pdf", "grab this file"],
            steps: [
                "Extract the URL from the user's request. If no URL was given, use `get_safari_url` or `get_chrome_url` to get the current page URL.",
                "Infer a filename from the URL path. Use `run_shell_command` with: curl -L -o ~/Downloads/FILENAME 'URL' to download it.",
                "Use `run_shell_command` with: ls -lh ~/Downloads/FILENAME to confirm the download and get file size.",
                "If the user asked to open it, use `open_file`. Otherwise use `reveal_in_finder` to show it in Finder.",
                "Report: 'Downloaded FILENAME (SIZE) to ~/Downloads/.'"
            ]
        ),
        Skill(
            name: "close_all_apps",
            description: "Quit all running applications except Finder and Executer.",
            exampleTriggers: ["close all apps", "quit everything", "close everything", "kill all apps", "shut it all down"],
            steps: [
                "Use `list_running_apps` to get all currently running applications.",
                "For each app that is NOT 'Finder' and NOT 'Executer', use `quit_app` to quit it. Call multiple `quit_app` in parallel for speed.",
                "Report: 'Closed N apps: [list of app names]. Finder and Executer still running.'"
            ]
        ),

        // MARK: Step 9 - New Skills

        Skill(
            name: "screenshot_ocr",
            description: "Take a screenshot and extract text from it using OCR.",
            exampleTriggers: ["screenshot and extract text", "OCR this screen", "read my screen", "capture and read text"],
            steps: [
                "Use `capture_screen` to take a screenshot and save it to the Desktop.",
                "Use `ocr_image` with the screenshot path to extract text from the image.",
                "Use `set_clipboard_text` to copy the extracted text to the clipboard.",
                "Report what text was found and that it's been copied to clipboard."
            ]
        ),
        Skill(
            name: "clipboard_summary",
            description: "Summarize recent clipboard history entries.",
            exampleTriggers: ["summarize my clipboard", "what did I copy", "clipboard history", "recent copies"],
            steps: [
                "Use `get_clipboard_history` with a reasonable limit (e.g. 20) to get recent entries.",
                "Summarize the entries — group similar items, note patterns, highlight the most recent and most important entries.",
                "Present a concise summary of what was copied and when."
            ]
        ),
        Skill(
            name: "tile_workspace",
            description: "Set up a workspace with multiple apps tiled on screen.",
            exampleTriggers: ["coding workspace", "set up workspace", "tile my apps", "arrange my workspace"],
            steps: [
                "Ask or infer which apps the user wants in their workspace based on context.",
                "Use `launch_app` for any apps that aren't running.",
                "Use `tile_windows_side_by_side` for 2 apps, or `arrange_windows` with the appropriate layout for 3-4 apps.",
                "Confirm which apps are arranged and in what layout."
            ]
        ),
        Skill(
            name: "daily_calendar",
            description: "Show today's calendar events.",
            exampleTriggers: ["what's on my calendar", "today's events", "upcoming events", "calendar today", "what meetings do I have"],
            steps: [
                "Use `query_calendar_events` to get today's events (default date range is now to +24h).",
                "Format the events as a clean bullet list with times and locations.",
                "If there are no events, say so clearly."
            ]
        ),
        Skill(
            name: "click_on",
            description: "Find a UI element on screen by its text/label and click it.",
            exampleTriggers: ["click on Send", "press the OK button", "tap Cancel", "click the search field"],
            steps: [
                "Use `capture_screen` to take a screenshot.",
                "Use `ocr_image` on the screenshot to extract text with bounding boxes.",
                "Find the text matching the user's description.",
                "Use `click` at the center of the matched element's bounding box.",
                "If the element is not found via OCR, try `click_element` which also uses accessibility APIs as a fallback."
            ]
        ),
        Skill(
            name: "fill_form",
            description: "Fill in a form on screen with the user's saved information.",
            exampleTriggers: ["fill in the form", "enter my details", "fill out this form", "auto-fill"],
            steps: [
                "Use `capture_screen` to see the current form.",
                "Use `ocr_image` to identify form fields and labels.",
                "Use `recall_memories` to get the user's saved personal info (name, email, etc.).",
                "For each field: `click` on the field, then `type_text` the appropriate value, then `press_key` tab to move to the next field.",
                "Confirm with the user before submitting."
            ]
        ),
        Skill(
            name: "dictate_here",
            description: "Type what the user says into the currently focused text field.",
            exampleTriggers: ["type what I say", "dictate", "voice type", "speech to text here"],
            steps: [
                "Click at the current cursor position to ensure focus.",
                "Tell the user to start speaking.",
                "Listen for voice input via the voice service.",
                "Use `type_text` to type the recognized text into the focused field."
            ]
        ),
    ]
}
