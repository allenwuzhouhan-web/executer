import Foundation

// MARK: - Create Automation Rule

struct CreateAutomationRuleTool: ToolDefinition {
    let name = "create_automation_rule"
    let description = "Create an automation rule from natural language. Example: 'When I connect my monitor, open Xcode and Terminal'. Supports triggers: display connect/disconnect, Wi-Fi changes, time of day, app launch/quit, battery level, power connect/disconnect, screen lock/unlock, focus mode changes."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "natural_language": JSONSchema.string(description: "The rule in natural language, e.g. 'When I connect my monitor, open Xcode and Terminal'")
        ], required: ["natural_language"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let input = try requiredString("natural_language", from: args)

        guard let parsed = RuleParser.parse(input) else {
            return "Could not parse that rule. Try a format like: 'When [trigger], [action]'. Supported triggers: connect/disconnect monitor, connect to Wi-Fi, every day at [time], open/close [app], battery below [N]%, plug in/unplug charger, lock/unlock screen."
        }

        let rule = AutomationRule(
            naturalLanguage: input,
            trigger: parsed.trigger,
            actions: parsed.actions
        )

        AutomationRuleManager.shared.addRule(rule)

        let actionDesc = parsed.actions.map { $0.displayDescription }.joined(separator: ", ")
        return "Rule created: \(parsed.trigger.displayDescription) \u{2192} \(actionDesc)"
    }
}

// MARK: - List Automation Rules

struct ListAutomationRulesTool: ToolDefinition {
    let name = "list_automation_rules"
    let description = "List all automation rules"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let rules = AutomationRuleManager.shared.rules
        guard !rules.isEmpty else {
            return "No automation rules configured."
        }

        var lines = ["Automation Rules (\(rules.count)):"]
        for rule in rules {
            let status = rule.enabled ? "ON" : "OFF"
            let actionDesc = rule.actions.map { $0.displayDescription }.joined(separator: " + ")
            lines.append("[\(status)] \(rule.trigger.displayDescription) \u{2192} \(actionDesc)")
            lines.append("  ID: \(rule.id)")
            lines.append("  Original: \"\(rule.naturalLanguage)\"")
            if let lastFired = rule.lastFiredAt {
                let formatter = RelativeDateTimeFormatter()
                lines.append("  Last fired: \(formatter.localizedString(for: lastFired, relativeTo: Date()))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Remove Automation Rule

struct RemoveAutomationRuleTool: ToolDefinition {
    let name = "remove_automation_rule"
    let description = "Remove an automation rule by its ID"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "rule_id": JSONSchema.string(description: "The ID of the rule to remove")
        ], required: ["rule_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let ruleId = try requiredString("rule_id", from: args)

        guard AutomationRuleManager.shared.rules.contains(where: { $0.id == ruleId }) else {
            return "No rule found with ID: \(ruleId)"
        }

        AutomationRuleManager.shared.removeRule(id: ruleId)
        return "Rule removed."
    }
}

// MARK: - Toggle Automation Rule

struct ToggleAutomationRuleTool: ToolDefinition {
    let name = "toggle_automation_rule"
    let description = "Enable or disable an automation rule by its ID"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "rule_id": JSONSchema.string(description: "The ID of the rule to toggle")
        ], required: ["rule_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let ruleId = try requiredString("rule_id", from: args)

        guard let newState = AutomationRuleManager.shared.toggleRule(id: ruleId) else {
            return "No rule found with ID: \(ruleId)"
        }

        return "Rule is now \(newState ? "enabled" : "disabled")."
    }
}
