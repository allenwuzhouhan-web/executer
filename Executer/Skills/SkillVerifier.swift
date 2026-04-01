import Foundation

// MARK: - Skill Verification Models

enum VerificationStatus: String, Codable {
    case pending
    case verified
    case rejected
}

struct StepAnalysis: Codable {
    let stepIndex: Int
    let stepText: String
    let referencedTools: [String]
    let maxToolTier: Int
    let flaggedPatterns: [String]
    var llmSafetyVerdict: String?
    var safe: Bool
}

struct SkillVerification: Codable {
    let skillName: String
    var status: VerificationStatus
    var riskScore: Int
    var stepAnalysis: [StepAnalysis]
    var verifiedAt: Date?
    var rejectionReason: String?
    var verifiedBy: String  // "ollama-qwen2.5", "rule-based", "manual"
}

// MARK: - Skill Verifier

/// Verifies imported skills for safety before activation.
/// Uses rule-based analysis + local Ollama model for flagged skills.
/// Safe skills auto-promote; risky ones go through overnight batch verification.
final class SkillVerifier {
    static let shared = SkillVerifier()

    private let verificationStorageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("skill_verifications.json")
    }()

    /// All known tool names in ToolRegistry — used to detect tool references in step text.
    private static let knownToolNames: Set<String> = {
        // Comprehensive list of all registered tools
        return Set([
            // Tier 0 (safe)
            "get_volume", "get_brightness", "get_dark_mode", "get_cursor_position",
            "get_clipboard_text", "get_clipboard_image", "get_system_info", "get_weather",
            "get_downloads_path", "get_safari_url", "get_safari_title", "get_chrome_url",
            "get_finder_window_path", "list_running_apps", "list_windows", "list_directory",
            "list_skills", "list_aliases", "list_automation_rules", "list_scheduled_tasks",
            "list_memories", "music_get_current", "query_calendar_events", "query_reminders",
            "dictionary_lookup", "thesaurus_lookup", "spell_check", "file_preview",
            "directory_tree", "get_file_info", "read_file", "read_pdf_text",
            "read_safari_page", "read_safari_html", "read_chrome_page",
            "search_file_contents", "find_files", "find_files_by_age",
            "capture_screen", "capture_window", "capture_screen_to_clipboard", "capture_area",
            "ocr_image", "get_clipboard_history", "search_clipboard_history", "recall_memories",
            "semantic_scholar_search", "get_paper_details",
            // Tier 1 (normal)
            "launch_app", "switch_to_app", "hide_app", "open_file", "reveal_in_finder",
            "open_url", "search_web", "open_url_in_safari", "new_safari_tab",
            "music_play", "music_pause", "music_next", "music_previous",
            "music_play_song", "music_search", "music_set_volume", "music_toggle_shuffle",
            "set_volume", "mute_volume", "unmute_volume", "set_brightness",
            "toggle_dark_mode", "toggle_night_shift", "toggle_dnd", "set_dnd_duration",
            "toggle_wifi", "toggle_bluetooth", "connect_bluetooth_device",
            "move_window", "resize_window", "fullscreen_window", "minimize_window",
            "tile_window_left", "tile_window_right", "tile_window_top_left", "center_window",
            "tile_windows_side_by_side", "move_window_to_space", "arrange_windows",
            "show_notification", "speak_text", "set_clipboard_text",
            "type_text", "press_key", "hotkey", "select_all_text",
            "move_cursor", "click", "click_element", "scroll", "drag",
            "create_reminder", "create_calendar_event", "create_note", "set_timer",
            "open_system_preferences_pane", "save_memory", "forget_memory",
            "create_alias", "remove_alias", "lock_screen", "sleep_display", "prevent_sleep",
            "fetch_url_content", "set_weather_key", "schedule_task", "open_terminal",
            "instant_search",
            // Tier 2 (elevated)
            "write_file", "edit_file", "append_to_file", "move_file", "copy_file",
            "trash_file", "create_folder", "open_file_with_app", "batch_rename_files",
            "quit_app", "force_quit_app", "close_window",
            "save_skill", "remove_skill",
            "create_automation_rule", "remove_automation_rule", "toggle_automation_rule",
            "clear_clipboard_history", "open_terminal_with_command", "sleep_system",
            "send_wechat_message", "send_message", "send_imessage", "send_whatsapp_message",
            // Tier 3 (critical)
            "run_shell_command", "shutdown", "restart", "log_out",
            // New document tools (will be registered later)
            "read_document", "create_document", "setup_python_docs",
            "extract_document_style", "list_document_styles",
        ])
    }()

    /// Dangerous patterns to scan for in step text — derived from SecurityGateway.
    private static let dangerousPatterns: [(pattern: String, reason: String)] = [
        ("curl.*\\|.*sh", "Piping remote script to shell"),
        ("wget.*\\|.*sh", "Piping remote script to shell"),
        ("eval\\s", "Eval execution"),
        ("sudo\\s", "Privilege escalation"),
        ("chmod.*777", "World-writable permissions"),
        ("rm\\s+-.*rf\\s+/", "Recursive delete from root"),
        ("rm\\s+-.*rf\\s+~/\\s*$", "Recursive delete of home"),
        ("mkfs\\s", "Filesystem format"),
        ("dd\\s+if=", "Raw disk write"),
        (">\\s*/etc/", "Overwrite system config"),
        ("launchctl\\s+load", "Loading launch daemons"),
        ("defaults\\s+write.*com\\.apple", "Modifying system defaults"),
        ("security\\s+delete-keychain", "Keychain deletion"),
        ("security\\s+dump-keychain", "Keychain dump"),
        ("csrutil\\s+disable", "SIP disable"),
        ("\\.ssh/", "SSH directory access"),
        ("\\.aws/", "AWS credentials access"),
    ]

    /// Data exfiltration patterns.
    private static let exfiltrationPatterns: [(pattern: String, reason: String)] = [
        ("curl\\s+-X\\s+POST", "HTTP POST — potential data exfiltration"),
        ("curl\\s+--data", "HTTP data upload"),
        ("wget\\s+--post", "HTTP POST via wget"),
        ("curl.*@", "File upload via curl"),
        ("nc\\s+-", "Netcat connection"),
        ("scp\\s+", "Secure copy to remote"),
        ("rsync.*:", "Remote sync"),
    ]

    private var compiledDangerousPatterns: [(regex: NSRegularExpression, reason: String)] = []
    private var compiledExfiltrationPatterns: [(regex: NSRegularExpression, reason: String)] = []

    private init() {
        compiledDangerousPatterns = Self.dangerousPatterns.compactMap { pattern, reason in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return (regex, reason)
        }
        compiledExfiltrationPatterns = Self.exfiltrationPatterns.compactMap { pattern, reason in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return (regex, reason)
        }
    }

    // MARK: - Public API

    /// Full verification pipeline for a single skill.
    func verifySkill(_ skill: SkillsManager.Skill) async -> SkillVerification {
        var stepAnalyses: [StepAnalysis] = []
        var totalRiskScore = 0
        var hasFlags = false

        // Step 1: Rule-based analysis for each step
        for (index, step) in skill.steps.enumerated() {
            let tools = extractToolReferences(from: step)
            let maxTier = tools.map { ToolSafetyClassifier.tier(for: $0).rawValue }.max() ?? 0
            let dangerous = scanForDangerousPatterns(step)
            let exfiltration = scanForExfiltrationPatterns(step)
            let allFlags = dangerous + exfiltration

            // Calculate risk for this step
            var stepRisk = 0
            for tool in tools {
                let tier = ToolSafetyClassifier.tier(for: tool)
                switch tier {
                case .safe: stepRisk += 0
                case .normal: stepRisk += 5
                case .elevated: stepRisk += 15
                case .critical: stepRisk += 30
                }
            }
            for flag in dangerous { _ = flag; stepRisk += 25 }
            for flag in exfiltration { _ = flag; stepRisk += 50 }

            let isSafe = allFlags.isEmpty && maxTier < ToolRiskTier.critical.rawValue
            if !isSafe { hasFlags = true }

            stepAnalyses.append(StepAnalysis(
                stepIndex: index,
                stepText: step,
                referencedTools: tools,
                maxToolTier: maxTier,
                flaggedPatterns: allFlags,
                llmSafetyVerdict: nil,
                safe: isSafe
            ))

            totalRiskScore += stepRisk
        }

        // Step 2: If flagged, try local LLM analysis
        var verifiedBy = "rule-based"
        if hasFlags {
            let ollamaAvailable = await OllamaRouter.shared.isAvailable()
            if ollamaAvailable {
                verifiedBy = "ollama-qwen2.5"
                for i in 0..<stepAnalyses.count where !stepAnalyses[i].safe {
                    let verdict = await analyzeStepWithOllama(stepAnalyses[i].stepText)
                    stepAnalyses[i].llmSafetyVerdict = verdict.reason
                    if !verdict.safe {
                        totalRiskScore += 20
                    } else {
                        // LLM says it's OK — reduce risk slightly
                        stepAnalyses[i].safe = true
                    }
                }
            }
            // If Ollama unavailable, stick with rule-based (conservative)
        }

        // Step 3: Final verdict
        let cap = min(totalRiskScore, 100)
        let status: VerificationStatus = cap <= 40 ? .verified : .rejected
        let rejectionReason: String? = status == .rejected
            ? "Risk score \(cap)/100. Flagged: \(stepAnalyses.filter { !$0.safe }.map { "step \($0.stepIndex + 1): \($0.flaggedPatterns.joined(separator: ", "))" }.joined(separator: "; "))"
            : nil

        let verification = SkillVerification(
            skillName: skill.name,
            status: status,
            riskScore: cap,
            stepAnalysis: stepAnalyses,
            verifiedAt: Date(),
            rejectionReason: rejectionReason,
            verifiedBy: verifiedBy
        )

        saveVerification(verification)
        return verification
    }

    /// Quick rule-based check only — used for immediate pre-screening on import.
    /// Returns true if skill is obviously safe (all Tier 0-1 tools, no shell commands, no flags).
    func quickSafetyCheck(_ skill: SkillsManager.Skill) -> Bool {
        for step in skill.steps {
            let tools = extractToolReferences(from: step)
            for tool in tools {
                if ToolSafetyClassifier.tier(for: tool).rawValue >= ToolRiskTier.elevated.rawValue {
                    return false
                }
            }
            if !scanForDangerousPatterns(step).isEmpty || !scanForExfiltrationPatterns(step).isEmpty {
                return false
            }
        }
        return true
    }

    /// Batch verify all pending skills. Called by TaskScheduler overnight.
    func verifyAllPending() async -> [SkillVerification] {
        let pending = SkillsManager.shared.pendingSkills()
        guard !pending.isEmpty else {
            print("[SkillVerifier] No pending skills to verify")
            return []
        }

        print("[SkillVerifier] Verifying \(pending.count) pending skills...")
        var results: [SkillVerification] = []

        for skill in pending {
            let result = await verifySkill(skill)
            results.append(result)
            print("[SkillVerifier] \(skill.name): \(result.status.rawValue) (risk: \(result.riskScore))")
        }

        return results
    }

    /// Schedule overnight verification via TaskScheduler (2 AM tonight).
    func scheduleOvernightVerification() {
        // Don't schedule if there's already a pending verification task
        let existingTasks = TaskScheduler.shared.pendingTasks()
        if existingTasks.contains(where: { $0.command == "__internal_verify_pending_skills" }) {
            print("[SkillVerifier] Overnight verification already scheduled")
            return
        }

        // Calculate next 2 AM
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 2
        components.minute = 0
        var targetDate = calendar.date(from: components) ?? Date()

        // If 2 AM has already passed today, schedule for tomorrow
        if targetDate <= Date() {
            targetDate = calendar.date(byAdding: .day, value: 1, to: targetDate) ?? Date()
        }

        _ = TaskScheduler.shared.addTask(
            command: "__internal_verify_pending_skills",
            scheduledDate: targetDate,
            label: "Skill Safety Verification"
        )
        print("[SkillVerifier] Scheduled overnight verification for \(targetDate)")
    }

    /// Get the stored verification report for a skill.
    func getVerification(for skillName: String) -> SkillVerification? {
        let all = loadVerifications()
        return all.first { $0.skillName == skillName }
    }

    /// Manually approve a skill (user override).
    func manuallyApprove(skillName: String) -> SkillVerification {
        var verification = getVerification(for: skillName) ?? SkillVerification(
            skillName: skillName,
            status: .verified,
            riskScore: 0,
            stepAnalysis: [],
            verifiedAt: Date(),
            rejectionReason: nil,
            verifiedBy: "manual"
        )
        verification.status = .verified
        verification.verifiedAt = Date()
        verification.verifiedBy = "manual"
        verification.rejectionReason = nil
        saveVerification(verification)
        return verification
    }

    // MARK: - Tool Reference Extraction

    /// Extracts tool names referenced in a step's text.
    private func extractToolReferences(from stepText: String) -> [String] {
        let lower = stepText.lowercased()
        var found: [String] = []

        for toolName in Self.knownToolNames {
            // Match tool_name with word boundaries (backtick-wrapped or standalone)
            if lower.contains(toolName) {
                // Verify it's a real reference, not a substring of another word
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: toolName))\\b|`\(NSRegularExpression.escapedPattern(for: toolName))`"
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(lower.startIndex..., in: lower)
                    if regex.firstMatch(in: lower, range: range) != nil {
                        found.append(toolName)
                    }
                }
            }
        }

        // Also check for generic shell/command references
        let shellIndicators = ["shell command", "terminal command", "bash", "zsh", "shell script"]
        for indicator in shellIndicators {
            if lower.contains(indicator) && !found.contains("run_shell_command") {
                found.append("run_shell_command")
            }
        }

        return found
    }

    // MARK: - Pattern Scanning

    private func scanForDangerousPatterns(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var flags: [String] = []
        for (regex, reason) in compiledDangerousPatterns {
            if regex.firstMatch(in: text, range: range) != nil {
                flags.append(reason)
            }
        }
        return flags
    }

    private func scanForExfiltrationPatterns(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var flags: [String] = []
        for (regex, reason) in compiledExfiltrationPatterns {
            if regex.firstMatch(in: text, range: range) != nil {
                flags.append(reason)
            }
        }
        return flags
    }

    // MARK: - Local LLM Analysis

    private struct OllamaSafetyVerdict {
        let safe: Bool
        let reason: String
    }

    private func analyzeStepWithOllama(_ stepText: String) async -> OllamaSafetyVerdict {
        guard let url = URL(string: "http://localhost:11434/api/generate") else {
            return OllamaSafetyVerdict(safe: false, reason: "Ollama URL invalid")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5  // Local model should be fast

        let prompt = """
        Analyze this automation step for safety risks on a personal Mac. \
        Consider: could it delete important files, leak private data, modify system settings dangerously, \
        or cause unrecoverable damage?

        Step: "\(stepText)"

        Respond ONLY with JSON: {"safe": true/false, "reason": "brief explanation"}
        """

        let body: [String: Any] = [
            "model": "qwen2.5:3b",
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 100]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return OllamaSafetyVerdict(safe: false, reason: "Failed to serialize request")
        }
        request.httpBody = bodyData

        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return OllamaSafetyVerdict(safe: false, reason: "Ollama returned non-200")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                return OllamaSafetyVerdict(safe: false, reason: "Could not parse Ollama response")
            }

            // Extract JSON from response
            return parseOllamaVerdict(responseText)
        } catch {
            return OllamaSafetyVerdict(safe: false, reason: "Ollama request failed: \(error.localizedDescription)")
        }
    }

    private func parseOllamaVerdict(_ text: String) -> OllamaSafetyVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to find JSON in response
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return OllamaSafetyVerdict(safe: false, reason: "No JSON in Ollama response")
        }

        let jsonStr = String(trimmed[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OllamaSafetyVerdict(safe: false, reason: "Invalid JSON from Ollama")
        }

        let safe = dict["safe"] as? Bool ?? false
        let reason = dict["reason"] as? String ?? "No reason provided"
        return OllamaSafetyVerdict(safe: safe, reason: reason)
    }

    // MARK: - Persistence

    private func loadVerifications() -> [SkillVerification] {
        guard FileManager.default.fileExists(atPath: verificationStorageURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: verificationStorageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([SkillVerification].self, from: data)
        } catch {
            print("[SkillVerifier] Failed to load verifications: \(error)")
            return []
        }
    }

    private func saveVerification(_ verification: SkillVerification) {
        var all = loadVerifications()
        all.removeAll { $0.skillName == verification.skillName }
        all.append(verification)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(all)
            try data.write(to: verificationStorageURL, options: .atomic)
        } catch {
            print("[SkillVerifier] Failed to save verification: \(error)")
        }
    }
}

// MARK: - Verification Tools

/// Manually trigger verification for a specific pending skill.
struct VerifySkillNowTool: ToolDefinition {
    let name = "verify_skill_now"
    let description = "Manually trigger safety verification for a pending skill right now, instead of waiting for the overnight batch."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "skill_name": JSONSchema.string(description: "Name of the pending skill to verify")
        ], required: ["skill_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let skillName = try requiredString("skill_name", from: args)

        // Find the pending skill
        guard let skill = SkillsManager.shared.pendingSkills().first(where: { $0.name == skillName }) else {
            // Check if it's already verified
            if SkillsManager.shared.skills.contains(where: { $0.name == skillName }) {
                return "Skill '\(skillName)' is already verified and active."
            }
            return "No pending skill found with name '\(skillName)'. Use list_pending_skills to see pending skills."
        }

        let result = await SkillVerifier.shared.verifySkill(skill)

        if result.status == .verified {
            SkillsManager.shared.promoteSkill(named: skillName)
            return """
            Skill '\(skillName)' VERIFIED and activated.
            Risk score: \(result.riskScore)/100
            Verified by: \(result.verifiedBy)
            Steps analyzed: \(result.stepAnalysis.count)
            All steps passed safety checks.
            """
        } else {
            SkillsManager.shared.rejectSkill(named: skillName, reason: result.rejectionReason ?? "Failed safety check")
            var report = """
            Skill '\(skillName)' REJECTED.
            Risk score: \(result.riskScore)/100
            Reason: \(result.rejectionReason ?? "Unknown")
            Flagged steps:
            """
            for step in result.stepAnalysis where !step.safe {
                report += "\n  Step \(step.stepIndex + 1): \(step.flaggedPatterns.joined(separator: ", "))"
                if let verdict = step.llmSafetyVerdict {
                    report += " — LLM: \(verdict)"
                }
            }
            report += "\n\nUse approve_skill to manually override if you trust this skill."
            return report
        }
    }
}

/// List all skills awaiting verification.
struct ListPendingSkillsTool: ToolDefinition {
    let name = "list_pending_skills"
    let description = "Show all imported skills that are awaiting safety verification."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let pending = SkillsManager.shared.pendingSkills()
        let rejected = SkillsManager.shared.rejectedSkills()

        if pending.isEmpty && rejected.isEmpty {
            return "No pending or rejected skills. All imported skills have been verified."
        }

        var result = ""

        if !pending.isEmpty {
            result += "**Pending Verification (\(pending.count)):**\n"
            for skill in pending {
                result += "  - \(skill.name): \(skill.description)\n"
                result += "    Steps: \(skill.steps.count)\n"
            }
        }

        if !rejected.isEmpty {
            result += "\n**Rejected (\(rejected.count)):**\n"
            for skill in rejected {
                let verification = SkillVerifier.shared.getVerification(for: skill.name)
                result += "  - \(skill.name): \(skill.description)\n"
                if let reason = verification?.rejectionReason {
                    result += "    Reason: \(reason)\n"
                }
                result += "    Use approve_skill to override.\n"
            }
        }

        return result
    }
}

/// Manual override to approve a rejected skill.
struct ApproveSkillTool: ToolDefinition {
    let name = "approve_skill"
    let description = "Manually approve a rejected or pending skill, overriding the safety check. Use when you trust the skill's source."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "skill_name": JSONSchema.string(description: "Name of the skill to approve")
        ], required: ["skill_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let skillName = try requiredString("skill_name", from: args)

        // Check pending and rejected
        let allStaged = SkillsManager.shared.pendingSkills() + SkillsManager.shared.rejectedSkills()
        guard allStaged.contains(where: { $0.name == skillName }) else {
            if SkillsManager.shared.skills.contains(where: { $0.name == skillName }) {
                return "Skill '\(skillName)' is already active."
            }
            return "No pending or rejected skill found with name '\(skillName)'."
        }

        let verification = SkillVerifier.shared.manuallyApprove(skillName: skillName)
        SkillsManager.shared.promoteSkill(named: skillName)

        return """
        Skill '\(skillName)' manually APPROVED and activated.
        Previous risk score: \(verification.riskScore)/100
        Override by: manual approval
        The skill is now available for use.
        """
    }
}
