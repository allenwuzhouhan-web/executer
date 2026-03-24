import Foundation

// MARK: - List Skills

struct ListSkillsTool: ToolDefinition {
    let name = "list_skills"
    let description = "List all available compound skills (multi-step workflows)"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let skills = SkillsManager.shared.skills
        if skills.isEmpty {
            return "No skills available."
        }
        let lines = skills.map { "- \($0.name): \($0.description)" }
        return "Available skills:\n\(lines.joined(separator: "\n"))"
    }
}

// MARK: - Save Skill

struct SaveSkillTool: ToolDefinition {
    let name = "save_skill"
    let description = "Save a new compound skill (reusable multi-step workflow) so it can be used in future commands. Use this after you successfully complete a complex multi-step task that might be useful again."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "skill_name": JSONSchema.string(description: "Short snake_case name for the skill (e.g. 'deploy_preview', 'batch_rename')"),
            "description": JSONSchema.string(description: "One-line description of what the skill does"),
            "example_triggers": JSONSchema.string(description: "Comma-separated example phrases that should trigger this skill"),
            "steps": JSONSchema.string(description: "The steps as a JSON array of strings, e.g. [\"Step 1\", \"Step 2\"]")
        ], required: ["skill_name", "description", "steps"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let skillName = try requiredString("skill_name", from: args)
        let description = try requiredString("description", from: args)
        let stepsJSON = try requiredString("steps", from: args)
        let triggersString = optionalString("example_triggers", from: args) ?? ""

        // Parse steps array from JSON string
        guard let stepsData = stepsJSON.data(using: .utf8),
              let steps = try? JSONSerialization.jsonObject(with: stepsData) as? [String],
              !steps.isEmpty else {
            throw ExecuterError.invalidArguments("steps must be a JSON array of strings, e.g. [\"Step 1\", \"Step 2\"]")
        }

        let triggers = triggersString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let skill = SkillsManager.Skill(
            name: skillName,
            description: description,
            exampleTriggers: triggers,
            steps: steps
        )

        SkillsManager.shared.addSkill(skill)
        return "Saved skill '\(skillName)' with \(steps.count) steps. It will be available in future commands."
    }
}

// MARK: - Remove Skill

struct RemoveSkillTool: ToolDefinition {
    let name = "remove_skill"
    let description = "Remove a user-created skill (built-in skills cannot be removed)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "skill_name": JSONSchema.string(description: "Name of the skill to remove")
        ], required: ["skill_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let skillName = try requiredString("skill_name", from: args)

        if SkillsManager.shared.removeSkill(named: skillName) {
            return "Removed skill '\(skillName)'."
        } else {
            return "Cannot remove '\(skillName)' — it's either a built-in skill or doesn't exist."
        }
    }
}
