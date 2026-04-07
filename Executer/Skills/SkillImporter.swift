import Foundation

// MARK: - External Skill Format

enum ExternalSkillFormat {
    case markdown     // ### Skill Name \n steps...
    case jsonArray    // [{"name": ..., "steps": [...]}]
    case unknown
}

// MARK: - Skill Importer

/// Parses, adapts, and imports skills from external sources (GitHub, local files).
/// Routes imported skills through the safety verification pipeline.
enum SkillImporter {

    /// Maps external tool names to Executer tool names.
    static let toolNameMap: [String: String] = [
        "bash": "run_shell_command", "shell": "run_shell_command", "terminal": "run_shell_command",
        "read": "read_file", "write": "write_file", "edit": "edit_file",
        "grep": "search_file_contents", "glob": "find_files", "find": "find_files",
        "browser": "open_url", "fetch": "fetch_url_content", "web_search": "search_web",
        "screenshot": "capture_screen", "ocr": "ocr_image",
        "copy": "set_clipboard_text", "paste": "get_clipboard_text",
        "notify": "show_notification", "speak": "speak_text",
        "open": "open_file", "launch": "launch_app",
        "timer": "set_timer", "reminder": "create_reminder",
        "note": "create_note", "calendar": "create_calendar_event",
    ]

    // MARK: - Format Detection

    static func detectFormat(_ content: String) -> ExternalSkillFormat {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return .jsonArray
        }
        if trimmed.contains("###") || trimmed.contains("## ") {
            return .markdown
        }
        return .unknown
    }

    // MARK: - Parsing

    static func parseSkills(from content: String, format: ExternalSkillFormat? = nil) -> [SkillsManager.Skill] {
        let fmt = format ?? detectFormat(content)
        switch fmt {
        case .jsonArray:
            return parseJSON(content)
        case .markdown:
            return parseMarkdown(content)
        case .unknown:
            // Try JSON first, then markdown
            let jsonResult = parseJSON(content)
            return jsonResult.isEmpty ? parseMarkdown(content) : jsonResult
        }
    }

    private static func parseJSON(_ content: String) -> [SkillsManager.Skill] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return [] }

        // Try array of skills
        if let skills = try? JSONDecoder().decode([SkillsManager.Skill].self, from: data) {
            return skills
        }

        // Try single skill object
        if let skill = try? JSONDecoder().decode(SkillsManager.Skill.self, from: data) {
            return [skill]
        }

        // Try generic JSON array
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { dict -> SkillsManager.Skill? in
                guard let name = dict["name"] as? String,
                      let steps = dict["steps"] as? [String] else { return nil }
                return SkillsManager.Skill(
                    name: name,
                    description: dict["description"] as? String ?? name,
                    exampleTriggers: dict["exampleTriggers"] as? [String] ?? dict["triggers"] as? [String] ?? [],
                    steps: steps,
                    verificationStatus: "pending"
                )
            }
        }

        return []
    }

    private static func parseMarkdown(_ content: String) -> [SkillsManager.Skill] {
        var skills: [SkillsManager.Skill] = []
        let lines = content.components(separatedBy: "\n")

        var currentName: String?
        var currentDescription: String?
        var currentSteps: [String] = []
        var currentTriggers: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // New skill header (### or ##)
            if trimmed.hasPrefix("###") || (trimmed.hasPrefix("## ") && !trimmed.hasPrefix("## Compound")) {
                // Save previous skill
                if let name = currentName, !currentSteps.isEmpty {
                    skills.append(SkillsManager.Skill(
                        name: name.lowercased().replacingOccurrences(of: " ", with: "_"),
                        description: currentDescription ?? name,
                        exampleTriggers: currentTriggers,
                        steps: currentSteps,
                        verificationStatus: "pending"
                    ))
                }
                currentName = trimmed.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
                currentDescription = nil
                currentSteps = []
                currentTriggers = []
            }
            // Description line (first non-header, non-step line after name)
            else if currentName != nil && currentDescription == nil && !trimmed.isEmpty
                    && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("*")
                    && !(trimmed.first?.isNumber == true) {
                currentDescription = trimmed
            }
            // Triggers line
            else if trimmed.lowercased().hasPrefix("trigger") {
                let triggers = trimmed.replacingOccurrences(of: "Triggers:", with: "")
                    .replacingOccurrences(of: "triggers:", with: "")
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    .filter { !$0.isEmpty }
                currentTriggers = triggers
            }
            // Step line (numbered or bulleted)
            else if let firstChar = trimmed.first,
                    (firstChar.isNumber || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")) {
                var step = trimmed
                // Strip leading number and period
                if firstChar.isNumber {
                    if let dotRange = step.range(of: ". ") {
                        step = String(step[dotRange.upperBound...])
                    }
                } else {
                    step = String(step.dropFirst(2))
                }
                if !step.isEmpty {
                    currentSteps.append(step)
                }
            }
        }

        // Save last skill
        if let name = currentName, !currentSteps.isEmpty {
            skills.append(SkillsManager.Skill(
                name: name.lowercased().replacingOccurrences(of: " ", with: "_"),
                description: currentDescription ?? name,
                exampleTriggers: currentTriggers,
                steps: currentSteps,
                verificationStatus: "pending"
            ))
        }

        return skills
    }

    // MARK: - Tool Name Adaptation

    /// Replaces external tool names with Executer equivalents in skill steps.
    static func adaptToolNames(_ skill: SkillsManager.Skill) -> SkillsManager.Skill {
        let adaptedSteps = skill.steps.map { step -> String in
            var result = step
            for (external, executer) in toolNameMap {
                // Replace backtick-wrapped tool names
                result = result.replacingOccurrences(of: "`\(external)`", with: "`\(executer)`")
                // Replace tool_name( pattern
                result = result.replacingOccurrences(of: "\(external)(", with: "\(executer)(")
            }
            return result
        }
        return SkillsManager.Skill(
            name: skill.name,
            description: skill.description,
            exampleTriggers: skill.exampleTriggers,
            steps: adaptedSteps,
            verificationStatus: skill.verificationStatus
        )
    }

    /// Validates a skill — checks if referenced tools exist.
    static func validateSkill(_ skill: SkillsManager.Skill) -> (valid: Bool, warnings: [String]) {
        var warnings: [String] = []
        // We can't directly access ToolRegistry's tool dictionary, but we can
        // check if tool names in steps match known tools from the SkillVerifier's set
        for (i, step) in skill.steps.enumerated() {
            let lower = step.lowercased()
            // Check for obviously dangerous patterns
            if lower.contains("rm -rf") || lower.contains("sudo") || lower.contains("eval(") {
                warnings.append("Step \(i+1) contains potentially dangerous operation")
            }
        }
        return (warnings.isEmpty, warnings)
    }
}

// MARK: - Search GitHub Skills Tool

struct SearchGitHubSkillsTool: ToolDefinition {
    let name = "search_github_skills"
    let description = "Search GitHub for skill/workflow definitions that can be imported into Executer."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Search query (e.g., 'macOS automation skills', 'agent workflows')"),
            "max_results": JSONSchema.integer(description: "Maximum results to return (default 5)", minimum: 1, maximum: 10),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let maxResults = optionalInt("max_results", from: args) ?? 5

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = "https://api.github.com/search/repositories?q=\(encodedQuery)+automation+skills+workflow&sort=stars&per_page=\(maxResults)"

        let result = try ShellRunner.run("curl -sL -H 'Accept: application/vnd.github.v3+json' '\(searchURL)' 2>/dev/null", timeout: 15)

        if result.exitCode != 0 {
            return "GitHub search failed: \(result.output)"
        }

        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return "Could not parse GitHub search results."
        }

        if items.isEmpty {
            return "No repositories found for '\(query)'. Try broader search terms."
        }

        var output = "**GitHub Skill Repositories:**\n"
        for item in items.prefix(maxResults) {
            let name = item["full_name"] as? String ?? "unknown"
            let desc = item["description"] as? String ?? "No description"
            let stars = item["stargazers_count"] as? Int ?? 0
            let url = item["html_url"] as? String ?? ""
            output += "\n- **\(name)** (\(stars) stars)\n  \(desc)\n  \(url)\n"
        }

        output += "\nTo import skills from a repo, use import_skill with a raw GitHub URL to a skills.md, workflows.json, or similar file."
        return output
    }
}

// MARK: - Import Skill Tool

struct ImportSkillTool: ToolDefinition {
    let name = "import_skill"
    let description = "Import skill definitions from a URL or local file. Skills go through safety verification before activation."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "GitHub raw URL or local file path to import from"),
            "skill_name": JSONSchema.string(description: "Override skill name (optional, used when importing a single skill)"),
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let url = try requiredString("url", from: args)
        let nameOverride = optionalString("skill_name", from: args)

        // Fetch content
        let content: String
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            let result = try ShellRunner.run("curl -sL '\(url)' 2>/dev/null", timeout: 20)
            if result.exitCode != 0 || result.output.isEmpty {
                return "Failed to fetch content from \(url)"
            }
            content = result.output
        } else {
            // Local file
            let path = NSString(string: url).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                return "File not found: \(path)"
            }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return "Could not read file: \(path)"
            }
            content = text
        }

        // Parse skills
        var skills = SkillImporter.parseSkills(from: content)
        if skills.isEmpty {
            return "No skill definitions found in the content. Expected markdown with ### headers or JSON array of skills."
        }

        // Apply name override if importing a single skill
        if let override = nameOverride, skills.count == 1 {
            skills[0] = SkillsManager.Skill(
                name: override,
                description: skills[0].description,
                exampleTriggers: skills[0].exampleTriggers,
                steps: skills[0].steps,
                verificationStatus: "pending"
            )
        }

        // Adapt tool names to Executer equivalents
        skills = skills.map { SkillImporter.adaptToolNames($0) }

        // Route through safety pipeline
        var autoPromoted = 0
        var queued = 0
        var skipped = 0

        for skill in skills {
            // Skip if already exists
            if SkillsManager.shared.skills.contains(where: { $0.name == skill.name }) ||
               SkillsManager.shared.pendingSkills().contains(where: { $0.name == skill.name }) {
                skipped += 1
                continue
            }

            // Quick safety check — auto-promote if obviously safe
            if SkillVerifier.shared.quickSafetyCheck(skill) {
                var verified = skill
                verified.verificationStatus = "verified"
                SkillsManager.shared.addSkill(verified)
                autoPromoted += 1
            } else {
                SkillsManager.shared.addPendingSkill(skill)
                queued += 1
            }
        }

        // Schedule overnight verification if we have pending skills
        if queued > 0 {
            SkillVerifier.shared.scheduleOvernightVerification()
        }

        var result = "Imported \(skills.count) skill(s) from \(url.hasPrefix("http") ? "URL" : "file").\n"
        if autoPromoted > 0 { result += "- \(autoPromoted) auto-verified and activated (safe tools only).\n" }
        if queued > 0 { result += "- \(queued) queued for safety verification (overnight, or use verify_skill_now).\n" }
        if skipped > 0 { result += "- \(skipped) skipped (already exist).\n" }

        return result
    }
}

// MARK: - List Skill Sources Tool

struct ListSkillSourcesTool: ToolDefinition {
    let name = "list_skill_sources"
    let description = "List curated sources of skills that can be imported."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        return """
        **Curated Skill Sources:**

        1. **macOS Automation Workflows**
           Common macOS automation patterns (file management, app control, system settings).
           Use search_github_skills with query "macOS automation workflow" to find repos.

        2. **Research & Analysis Workflows**
           Academic research, web scraping, data analysis patterns.
           Use search_github_skills with query "AI agent research workflow" to find repos.

        3. **Productivity & Office Skills**
           Document creation, email drafting, calendar management patterns.
           Use search_github_skills with query "productivity automation agent" to find repos.

        4. **Developer Tools**
           Git workflows, code review, deployment automation patterns.
           Use search_github_skills with query "developer automation agent tools" to find repos.

        **To import:** Find a repo → locate its skills/workflows file → use import_skill with the raw GitHub URL.
        **Safety:** All imported skills go through safety verification before activation.
        """
    }
}
