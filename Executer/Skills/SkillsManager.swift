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
        var verificationStatus: String?  // "pending", "verified", "rejected" (nil = built-in = verified)
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

    private let pendingSkillsURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_skills.json")
    }()

    private let rejectedSkillsURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rejected_skills.json")
    }()

    private(set) var stagedPendingSkills: [Skill] = []
    private(set) var stagedRejectedSkills: [Skill] = []

    private init() {
        skills = Self.defaultSkills + loadUserSkills()
        stagedPendingSkills = loadSkills(from: pendingSkillsURL)
        stagedRejectedSkills = loadSkills(from: rejectedSkillsURL)
        print("[Skills] Loaded \(skills.count) active (\(Self.defaultSkills.count) built-in, \(skills.count - Self.defaultSkills.count) user), \(stagedPendingSkills.count) pending, \(stagedRejectedSkills.count) rejected")
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

    // MARK: - Staged Skills (Safety Pipeline)

    /// Add a skill to the pending queue (not yet verified).
    func addPendingSkill(_ skill: Skill) {
        var pending = skill
        pending.verificationStatus = "pending"
        // Remove if already exists in any stage
        stagedPendingSkills.removeAll { $0.name == skill.name }
        stagedRejectedSkills.removeAll { $0.name == skill.name }
        skills.removeAll { $0.name == skill.name }
        stagedPendingSkills.append(pending)
        saveSkills(stagedPendingSkills, to: pendingSkillsURL)
        saveSkills(stagedRejectedSkills, to: rejectedSkillsURL)
        print("[Skills] Added pending skill: \(skill.name)")
    }

    /// Promote a pending/rejected skill to active (verified).
    func promoteSkill(named name: String) {
        // Find in pending or rejected
        if let skill = stagedPendingSkills.first(where: { $0.name == name }) ??
           stagedRejectedSkills.first(where: { $0.name == name }) {
            var verified = skill
            verified.verificationStatus = "verified"
            stagedPendingSkills.removeAll { $0.name == name }
            stagedRejectedSkills.removeAll { $0.name == name }
            // Add to active skills
            skills.removeAll { $0.name == name }
            skills.append(verified)
            cachedPromptSection = nil
            saveUserSkills()
            saveSkills(stagedPendingSkills, to: pendingSkillsURL)
            saveSkills(stagedRejectedSkills, to: rejectedSkillsURL)
            print("[Skills] Promoted skill to active: \(name)")
        }
    }

    /// Reject a pending skill with a reason.
    func rejectSkill(named name: String, reason: String) {
        if var skill = stagedPendingSkills.first(where: { $0.name == name }) {
            skill.verificationStatus = "rejected"
            stagedPendingSkills.removeAll { $0.name == name }
            stagedRejectedSkills.removeAll { $0.name == name }
            stagedRejectedSkills.append(skill)
            saveSkills(stagedPendingSkills, to: pendingSkillsURL)
            saveSkills(stagedRejectedSkills, to: rejectedSkillsURL)
            print("[Skills] Rejected skill: \(name) — \(reason)")
        }
    }

    /// Returns all pending skills.
    func pendingSkills() -> [Skill] {
        return stagedPendingSkills
    }

    /// Returns all rejected skills.
    func rejectedSkills() -> [Skill] {
        return stagedRejectedSkills
    }

    /// Batch import skills — routes through safety pipeline.
    func importSkills(_ newSkills: [Skill]) -> (added: Int, skipped: Int) {
        var added = 0
        var skipped = 0
        for skill in newSkills {
            // Skip if already exists (active, pending, or rejected)
            if skills.contains(where: { $0.name == skill.name }) ||
               stagedPendingSkills.contains(where: { $0.name == skill.name }) {
                skipped += 1
                continue
            }
            // Quick safety check — auto-promote if obviously safe
            if SkillVerifier.shared.quickSafetyCheck(skill) {
                var verified = skill
                verified.verificationStatus = "verified"
                skills.append(verified)
                cachedPromptSection = nil
                saveUserSkills()
                added += 1
                print("[Skills] Auto-promoted safe skill: \(skill.name)")
            } else {
                addPendingSkill(skill)
                added += 1
            }
        }
        return (added, skipped)
    }

    // MARK: - Prompt Injection

    /// Formats all active (verified) skills as a prompt section for the LLM system message.
    func promptSection() -> String {
        if let cached = cachedPromptSection { return cached }

        // Only include built-in (nil status) or verified skills
        let activeSkills = skills.filter { $0.verificationStatus == nil || $0.verificationStatus == "verified" }
        guard !activeSkills.isEmpty else { return "" }

        var lines = [
            "",
            "## Compound Skills",
            "",
            "When a user's request matches one of these skills, follow the steps using your available tools.",
            "When a step says to call multiple tools, do so in a single response (parallel tool calls).",
            ""
        ]

        for skill in activeSkills {
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
        return loadSkills(from: userSkillsURL)
    }

    private func loadSkills(from url: URL) -> [Skill] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Skill].self, from: data)
        } catch {
            print("[Skills] Failed to load skills from \(url.lastPathComponent): \(error)")
            return []
        }
    }

    private func saveUserSkills() {
        let builtInNames = Set(Self.defaultSkills.map(\.name))
        let userOnly = skills.filter { !builtInNames.contains($0.name) }
        saveSkills(userOnly, to: userSkillsURL)
    }

    private func saveSkills(_ skillList: [Skill], to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(skillList)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[Skills] Failed to save skills to \(url.lastPathComponent): \(error)")
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

        // MARK: Additional Built-in Skills

        Skill(
            name: "explain_code",
            description: "Explain code from clipboard or user input. Breaks down what the code does line-by-line.",
            exampleTriggers: ["explain this code", "what does this code do", "explain my code", "code explanation"],
            steps: [
                "If the user provided code directly, use that. Otherwise use `get_clipboard_text` to get code from the clipboard.",
                "Read through the code and identify the language, key patterns, and overall purpose.",
                "Explain the code line-by-line or block-by-block, highlighting key patterns, idioms, and concepts.",
                "Summarize the overall purpose and any potential issues or improvements."
            ]
        ),
        Skill(
            name: "convert_units",
            description: "Convert between units with contextual explanation. For complex conversions the local calculator can't handle.",
            exampleTriggers: ["convert 5 miles to nautical miles", "how many cups in a gallon", "unit conversion"],
            steps: [
                "Parse the source value, source unit, and target unit from the user's request.",
                "Calculate the conversion using the appropriate conversion factor.",
                "Present the result with the conversion factor shown (e.g. '1 mile = 1.15078 nautical miles') so the user learns the relationship.",
                "If the conversion is ambiguous (e.g. fluid vs dry ounces), clarify which interpretation was used."
            ]
        ),
        Skill(
            name: "lookup_formula",
            description: "Search the web for a formula or equation not in the local database.",
            exampleTriggers: ["find formula for", "look up equation", "search for theorem"],
            steps: [
                "Use `instant_search` (DuckDuckGo) with a query like '[topic] formula equation' to find the formula.",
                "Extract the relevant formula from the search results or follow up with `fetch_url_content` on the most promising result.",
                "Present the formula in Unicode math notation for readability.",
                "Include a brief explanation of each variable and when the formula applies.",
                "Use `set_clipboard_text` to copy the formula to the clipboard."
            ]
        ),
        Skill(
            name: "generate_password",
            description: "Generate a secure random password and copy to clipboard.",
            exampleTriggers: ["generate password", "new password", "random password", "secure password"],
            steps: [
                "Use `run_shell_command` with `openssl rand -base64 24` to generate a random 32-character password.",
                "If the user specified requirements (length, no special chars, etc.), adjust: e.g. `openssl rand -hex 16` for alphanumeric only.",
                "Use `set_clipboard_text` to copy the generated password to the clipboard.",
                "Report: 'Password generated and copied to clipboard.' Do NOT display the full password in the response for security — show only the first 4 characters followed by dots."
            ]
        ),
        Skill(
            name: "quick_math",
            description: "Solve a math problem step-by-step, showing work.",
            exampleTriggers: ["solve this equation", "step by step math", "show the work", "solve for x"],
            steps: [
                "Parse the math problem from the user's request or clipboard.",
                "Break the problem into clear steps, showing each algebraic or arithmetic operation.",
                "Present each step on its own line with a brief explanation of what was done.",
                "State the final answer clearly and verify it by substituting back if applicable."
            ]
        ),
        Skill(
            name: "text_transform",
            description: "Transform text: uppercase, lowercase, title case, camelCase, snake_case, reverse, word count.",
            exampleTriggers: ["uppercase this", "make lowercase", "to camelCase", "to snake_case", "reverse text", "word count"],
            steps: [
                "If the user provided text directly, use that. Otherwise use `get_clipboard_text` to get text from the clipboard.",
                "Apply the requested transformation (uppercase, lowercase, title case, camelCase, snake_case, reverse, or word count).",
                "Use `set_clipboard_text` to copy the transformed result to the clipboard.",
                "Report the result and confirm it was copied to clipboard."
            ]
        ),
        Skill(
            name: "batch_rename",
            description: "Rename multiple files in a directory with a pattern.",
            exampleTriggers: ["rename files", "batch rename", "rename all files in"],
            steps: [
                "Use `run_shell_command` with `ls` on the target directory to list files that match the criteria.",
                "Generate a preview of the new filenames based on the user's pattern (e.g. prefix, suffix, numbering, find-replace).",
                "Present the before/after preview and ask the user to confirm.",
                "After confirmation, use `run_shell_command` with `mv` for each file to rename them.",
                "Report: 'Renamed N files in [directory].'"
            ]
        ),
        Skill(
            name: "git_summary",
            description: "Summarize recent git activity in the current or specified directory.",
            exampleTriggers: ["git summary", "recent commits", "git activity", "what changed in git"],
            steps: [
                "Use `run_shell_command` with `git -C [dir] log --oneline -20` to get recent commit messages.",
                "Use `run_shell_command` with `git -C [dir] diff --stat` to see uncommitted changes.",
                "Use `run_shell_command` with `git -C [dir] branch -a` to list branches.",
                "Present a clean summary: recent commits as a bullet list, uncommitted changes highlighted, current branch noted."
            ]
        ),
        Skill(
            name: "open_project",
            description: "Open a development project with IDE, terminal, and browser.",
            exampleTriggers: ["open project", "start coding", "open my project", "dev setup"],
            steps: [
                "Identify the project directory from the user's request or recent memory. Use `run_shell_command` to verify the directory exists.",
                "Detect the project type by checking for .xcodeproj (Xcode), package.json (VS Code + Node), Cargo.toml (Rust), etc.",
                "Use `launch_app` to open the appropriate IDE (Xcode for Swift, VS Code for web/JS/Python projects).",
                "Use `run_shell_command` to open a terminal in the project directory: `open -a Terminal [dir]`.",
                "If the project has a web component (package.json with a start script), optionally open http://localhost:3000 in the browser.",
                "Report: 'Project [name] opened — IDE, terminal ready.'"
            ]
        ),
        Skill(
            name: "translate_clipboard",
            description: "Translate whatever's on the clipboard, auto-detecting the source language.",
            exampleTriggers: ["translate clipboard", "translate what I copied", "translate my clipboard"],
            steps: [
                "Use `get_clipboard_text` to get the current clipboard contents.",
                "Detect the source language from the text.",
                "Translate the text to English by default, or to the user's specified target language.",
                "Use `set_clipboard_text` to copy the translated text to the clipboard.",
                "Report: 'Translated from [source language] to [target language] — copied to clipboard.' Show the translation in the response."
            ]
        ),
        Skill(
            name: "schedule_message",
            description: "Schedule a message to be sent at a specific time.",
            exampleTriggers: ["schedule message", "send later", "remind me to text", "send message at"],
            steps: [
                "Parse the recipient, message body, and target send time from the user's request.",
                "Calculate the delay from now until the target time.",
                "Use `set_timer` with the calculated delay and a label like 'Send message to [recipient]: [message preview]'.",
                "Use `save_memory` with category 'scheduled_message' to persist the full details (recipient, message, time) so it survives restarts.",
                "Report: 'Message to [recipient] scheduled for [time]. I'll remind you when it's time to send.'"
            ]
        ),
        Skill(
            name: "summarize_clipboard",
            description: "Summarize whatever text is on the clipboard.",
            exampleTriggers: ["summarize clipboard", "summarize what I copied", "tldr clipboard"],
            steps: [
                "Use `get_clipboard_text` to get the current clipboard contents.",
                "Analyze the text and provide a concise summary: one-sentence overview followed by 3-5 bullet points of key information.",
                "Use `set_clipboard_text` to copy the summary to the clipboard.",
                "Report the summary and confirm it was copied to clipboard."
            ]
        ),
        Skill(
            name: "define_word",
            description: "Get a rich word definition with etymology, pronunciation, and usage examples.",
            exampleTriggers: ["define", "what does the word mean", "etymology of", "definition of"],
            steps: [
                "Use `dictionary_lookup` to get the primary definition and pronunciation of the word.",
                "Use `instant_search` with a query like '[word] etymology origin' to find etymology information.",
                "Present the result: pronunciation (phonetic), part of speech, primary definition, etymology/origin, and 2-3 example sentences showing the word in context.",
                "If the word has multiple meanings, list the top 2-3 most common ones."
            ]
        ),
        Skill(
            name: "countdown",
            description: "Calculate days/hours until a specific date or event.",
            exampleTriggers: ["countdown to", "how many days until", "time until", "days left"],
            steps: [
                "Parse the target date or event from the user's request. If it's a named event (e.g. 'Christmas'), resolve to the next occurrence.",
                "Calculate the difference from the current date/time to the target date.",
                "Present in human-readable format: X days, Y hours, Z minutes remaining.",
                "If the event is a recurring one, also mention when the following occurrence is."
            ]
        ),
        Skill(
            name: "screen_break",
            description: "Remind to take a break with timer and notification.",
            exampleTriggers: ["screen break", "break reminder", "eye rest", "take a break", "20-20-20"],
            steps: [
                "Use `set_timer` with the user's specified duration, or default to 20 minutes, with label 'Screen Break — Look 20 feet away for 20 seconds'.",
                "Use `show_notification` to confirm: 'Break timer set for [duration]. I'll notify you when it's time.'",
                "When the timer fires, use `show_notification` with title 'Screen Break' and body '20-20-20: Look at something 20 feet away for 20 seconds. Blink and stretch!'",
                "Optionally, if the user requested it, use `run_shell_command` with `pmset displaysleepnow` to briefly sleep the display as a forcing function."
            ]
        ),

        // MARK: Document Creation & Style Skills

        Skill(
            name: "create_presentation",
            description: "Create a PowerPoint presentation from the user's description. Applies saved style if available.",
            exampleTriggers: ["create a presentation", "make slides", "powerpoint about", "create a deck", "make a pptx"],
            steps: [
                "Check if python-pptx is installed: call `setup_python_docs` if needed.",
                "Check available styles with `list_document_styles`. If the user has a saved style, use it.",
                "Plan the slide structure from the user's description: title slide, content slides with bullets, conclusion slide.",
                "Call `create_document` with format='pptx', the planned content JSON, and style_profile if available.",
                "Open the created file with `open_file`.",
                "Report: 'Created [N]-slide presentation at [path].'"
            ]
        ),
        Skill(
            name: "learn_document_style",
            description: "Extract and save the visual style from an existing document for future reuse.",
            exampleTriggers: ["learn my style", "extract style from", "remember this format", "copy this style", "learn my presentation style"],
            steps: [
                "If no file path given, use `find_files` to search ~/Documents/works for recent .pptx/.docx files.",
                "Call `extract_document_style` with the file path and a descriptive profile name.",
                "Report what was extracted: fonts, colors, layout count, dimensions.",
                "Use `save_memory` to remember the user's preferred style for this type of document."
            ]
        ),
        Skill(
            name: "read_office_document",
            description: "Read and summarize a Word, PowerPoint, or Excel file.",
            exampleTriggers: ["read this pptx", "summarize this word doc", "what's in this spreadsheet", "open and read this document"],
            steps: [
                "Call `setup_python_docs` if needed (first time only).",
                "Call `read_document` with the file path and format='structure' for full content.",
                "Summarize the content: for PPTX list slide titles and key points, for DOCX summarize sections, for XLSX describe sheets and data.",
                "Copy the summary to clipboard with `set_clipboard_text`."
            ]
        ),
        Skill(
            name: "create_word_document",
            description: "Create a Word document with formatted sections, headings, and bullets.",
            exampleTriggers: ["create a word doc", "write a document", "make a docx", "create a report"],
            steps: [
                "Check if python-docx is installed: call `setup_python_docs` if needed.",
                "Check available styles with `list_document_styles`. If the user has a saved DOCX style, use it.",
                "Plan the document structure: sections with headings, body paragraphs, and bullet points.",
                "Call `create_document` with format='docx', the planned content JSON, and style_profile if available.",
                "Open the created file with `open_file`.",
                "Report: 'Created document at [path].'"
            ]
        ),
        Skill(
            name: "create_spreadsheet",
            description: "Create an Excel spreadsheet with structured data.",
            exampleTriggers: ["create a spreadsheet", "make an excel", "create xlsx", "make a data table"],
            steps: [
                "Check if openpyxl is installed: call `setup_python_docs` if needed.",
                "Plan the spreadsheet structure: sheet names, header rows, and data rows.",
                "Call `create_document` with format='xlsx' and the planned content JSON.",
                "Open the created file with `open_file`.",
                "Report: 'Created spreadsheet at [path].'"
            ]
        ),

        // MARK: UI Automation & App Control Skills

        Skill(
            name: "fullscreen_app",
            description: "Switch to an app and make it fullscreen.",
            exampleTriggers: ["fullscreen minecraft", "make safari fullscreen", "fullscreen this app", "maximize PowerPoint"],
            steps: [
                "Use `switch_to_app` to bring the target app to front. If not running, use `launch_app` first.",
                "Wait briefly for the app to activate.",
                "Use `fullscreen_window` to toggle fullscreen mode on the active window.",
                "Report: '[App] is now fullscreen.'"
            ]
        ),
        Skill(
            name: "app_automation",
            description: "Perform a sequence of UI actions in an app: launch, click buttons, type text, navigate menus.",
            exampleTriggers: ["click play in minecraft", "press the start button", "navigate to settings in", "interact with"],
            steps: [
                "Use `switch_to_app` or `launch_app` to ensure the target app is frontmost.",
                "Use `read_screen` to see all visible UI elements and their positions.",
                "Identify the target element (button, menu item, text field) from the UI tree.",
                "Use `click_element` with the element's description to click it. If that fails, use `click` at the element's coordinates.",
                "For text input: use `click_element` on the text field, then `type_text` to enter text, then `press_key` return if needed.",
                "Report what was done: 'Clicked [element] in [app].'"
            ]
        ),
        Skill(
            name: "multi_step_ui",
            description: "Execute multiple UI actions in sequence: fullscreen, click, type, navigate across apps.",
            exampleTriggers: ["fullscreen and click play", "open and then click", "switch to app and do", "do this then that"],
            steps: [
                "Break the user's request into individual actions (e.g., 'fullscreen' + 'click play').",
                "Execute each action in order using the appropriate tools:",
                "  - App switching: `switch_to_app` or `launch_app`",
                "  - Window control: `fullscreen_window`, `resize_window`, `minimize_window`",
                "  - Clicking: `click_element` (by description) or `click` (by coordinates)",
                "  - Typing: `type_text`, `press_key`, `hotkey`",
                "  - Scrolling: `scroll`",
                "Wait briefly between actions to let the UI settle.",
                "Report each completed action."
            ]
        ),
        Skill(
            name: "navigate_menu",
            description: "Navigate an app's menu bar to find and click a specific menu item.",
            exampleTriggers: ["go to file menu", "click edit paste", "find in menu", "menu bar"],
            steps: [
                "Use `read_screen` to see the current app's UI and menu bar items.",
                "Use `click_element` on the target menu item (e.g., 'File' in the menu bar).",
                "If a submenu is needed, use `click_element` again on the submenu item.",
                "Report: 'Selected [menu item] from [menu].'"
            ]
        ),
    ]
}
