import Foundation

/// Converts high-confidence patterns into actionable rules injected into the system prompt.
/// Closes the observe → learn → apply loop.
enum LearningFeedbackLoop {

    /// Scan patterns and generate rules. Called periodically from LearningManager.
    static func generateRules() async {
        let apps = LearningDatabase.shared.allAppNames()

        for (appName, _, _) in apps {
            let patterns = LearningDatabase.shared.topPatterns(forApp: appName, limit: 5)
            for pattern in patterns where pattern.frequency >= 10 {
                // Check if rule already exists for this pattern
                guard !LearningDatabase.shared.hasRuleForPattern(patternId: pattern.id.uuidString) else { continue }

                // Use LLM to convert pattern to an actionable rule
                let stepsDesc = pattern.actions.map { "\($0.type.rawValue) on \($0.elementTitle)" }.joined(separator: " -> ")
                let prompt = """
                Convert this observed user behavior into a concise, actionable rule for an AI assistant.
                App: \(appName)
                Pattern (observed \(pattern.frequency)x): \(stepsDesc)

                Output ONE rule as a single sentence. Example: "When creating presentations in Keynote, always start with the Minimal White theme."
                """

                let messages = [
                    ChatMessage(role: "system", content: "Convert behavioral patterns into actionable rules. Output ONE sentence only."),
                    ChatMessage(role: "user", content: prompt)
                ]

                let service = LLMServiceManager.shared.currentService
                guard let response = try? await service.sendChatRequest(messages: messages, tools: nil, maxTokens: 100),
                      let ruleText = response.text else { continue }

                let cleanRule = ruleText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanRule.isEmpty else { continue }

                LearningDatabase.shared.executeSQL("""
                    INSERT OR IGNORE INTO learned_rules (id, rule_text, source_pattern_id, confidence, created_at)
                    VALUES (?, ?, ?, ?, ?)
                """, bindings: [
                    UUID().uuidString,
                    cleanRule,
                    pattern.id.uuidString,
                    0.7,
                    Date().timeIntervalSince1970
                ])

                print("[LearningFeedback] Generated rule from pattern in \(appName): \(cleanRule.prefix(80))")
            }
        }
    }

    /// Returns learned rules for prompt injection.
    static func promptSection() -> String {
        let rules = LearningDatabase.shared.queryRules(minConfidence: 0.5, limit: 10)
        guard !rules.isEmpty else { return "" }

        var lines = ["\n## Learned Rules (from observing you)"]
        for rule in rules {
            lines.append("- \(rule)")
        }
        return lines.joined(separator: "\n")
    }
}
