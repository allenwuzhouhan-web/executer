import Foundation

/// After complex tasks, evaluates the agent's output quality and optionally triggers retry.
actor PostTaskEvaluator {
    static let shared = PostTaskEvaluator()

    enum TaskType {
        case documentCreation(filePath: String)
        case fileOperation(paths: [String])
        case screenTask
        case research
        case general
    }

    struct EvaluationResult {
        let passed: Bool
        let score: Double       // 0.0-1.0
        let feedback: String
        let shouldRetry: Bool
    }

    /// Evaluate the result of a task.
    func evaluate(
        goal: String,
        result: String,
        taskType: TaskType
    ) async -> EvaluationResult {
        switch taskType {
        case .documentCreation(let filePath):
            return await evaluateDocument(goal: goal, filePath: filePath)
        case .fileOperation(let paths):
            return evaluateFileOperation(paths: paths)
        case .screenTask:
            return await evaluateScreenTask(goal: goal)
        case .research:
            return await evaluateResearch(goal: goal, result: result)
        case .general:
            return EvaluationResult(passed: true, score: 0.8, feedback: "", shouldRetry: false)
        }
    }

    /// Classify what type of task this was based on command + tool results.
    static func classifyTaskType(_ command: String, messages: [ChatMessage]) -> TaskType {
        let lower = command.lowercased()

        // Document creation
        let docKeywords = ["presentation", "pptx", "powerpoint", "slide", "word", "docx", "excel", "xlsx", "spreadsheet", "document"]
        if docKeywords.contains(where: { lower.contains($0) }) {
            // Try to extract output path from tool results
            for msg in messages where msg.role == "tool" {
                if let content = msg.content {
                    // Look for file paths in results
                    if let range = content.range(of: "(?:/|~)[^\\s\"]+\\.(?:pptx|docx|xlsx|pdf|txt)", options: .regularExpression) {
                        let path = String(content[range])
                        let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
                        return .documentCreation(filePath: expanded)
                    }
                }
            }
            return .documentCreation(filePath: "")
        }

        // Research
        if lower.contains("research") || lower.contains("investigate") || lower.contains("find out") || lower.contains("look up") {
            return .research
        }

        // Screen task
        let uiKeywords = ["click", "type in", "navigate to", "open app", "fullscreen", "drag", "fill out", "form"]
        if uiKeywords.contains(where: { lower.contains($0) }) {
            return .screenTask
        }

        return .general
    }

    // MARK: - Evaluation Strategies

    private func evaluateDocument(goal: String, filePath: String) async -> EvaluationResult {
        guard !filePath.isEmpty else {
            return EvaluationResult(passed: true, score: 0.7, feedback: "Could not determine output file path.", shouldRetry: false)
        }

        let fm = FileManager.default
        let expanded = filePath.hasPrefix("~") ? (filePath as NSString).expandingTildeInPath : filePath
        guard fm.fileExists(atPath: expanded) else {
            return EvaluationResult(passed: false, score: 0.0, feedback: "Output file does not exist at \(filePath).", shouldRetry: true)
        }

        // File exists — for now, pass with high confidence
        // A deeper check would read the file and evaluate content via LLM
        let attrs = try? fm.attributesOfItem(atPath: expanded)
        let size = (attrs?[.size] as? Int) ?? 0
        if size < 100 {
            return EvaluationResult(passed: false, score: 0.2, feedback: "Output file is suspiciously small (\(size) bytes).", shouldRetry: true)
        }

        return EvaluationResult(passed: true, score: 0.9, feedback: "Document created successfully (\(size / 1024)KB).", shouldRetry: false)
    }

    private func evaluateFileOperation(paths: [String]) -> EvaluationResult {
        let fm = FileManager.default
        var missing: [String] = []
        for path in paths {
            let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
            if !fm.fileExists(atPath: expanded) {
                missing.append(path)
            }
        }
        if missing.isEmpty {
            return EvaluationResult(passed: true, score: 1.0, feedback: "All files verified.", shouldRetry: false)
        }
        return EvaluationResult(
            passed: false, score: 0.0,
            feedback: "Missing files: \(missing.joined(separator: ", "))",
            shouldRetry: true
        )
    }

    private func evaluateScreenTask(goal: String) async -> EvaluationResult {
        // Take a screenshot and read the screen state
        let perception = await VisionEngine.shared.perceiveAsText(maxElements: 30)
        guard !perception.isEmpty else {
            return EvaluationResult(passed: true, score: 0.7, feedback: "Could not read screen for verification.", shouldRetry: false)
        }

        let prompt = """
        Did this screen state achieve the goal? Be brief.
        Goal: \(goal)
        Screen: \(perception.prefix(1500))

        Output JSON: {"achieved": true/false, "explanation": "why"}
        """

        let messages = [
            ChatMessage(role: "system", content: "Evaluate if screen state matches a goal. Output ONLY JSON."),
            ChatMessage(role: "user", content: prompt)
        ]

        let service = OpenAICompatibleService(provider: .deepseek, model: "deepseek-chat")
        guard let response = try? await service.sendChatRequest(messages: messages, tools: nil, maxTokens: 128),
              let text = response.text else {
            return EvaluationResult(passed: true, score: 0.7, feedback: "Could not evaluate screen.", shouldRetry: false)
        }

        // Extract JSON
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
           let data = String(trimmed[start...end]).data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let achieved = (parsed["achieved"] as? Bool) ?? true
            let explanation = (parsed["explanation"] as? String) ?? ""
            return EvaluationResult(
                passed: achieved, score: achieved ? 0.9 : 0.3,
                feedback: explanation, shouldRetry: !achieved
            )
        }

        return EvaluationResult(passed: true, score: 0.7, feedback: "Evaluation inconclusive.", shouldRetry: false)
    }

    private func evaluateResearch(goal: String, result: String) async -> EvaluationResult {
        guard result.count > 50 else {
            return EvaluationResult(passed: false, score: 0.2, feedback: "Response is too short for a research question.", shouldRetry: true)
        }

        let prompt = """
        Does this response adequately answer the research question? Be brief.
        Question: \(goal.prefix(200))
        Answer (first 1000 chars): \(result.prefix(1000))

        Output JSON: {"adequate": true/false, "score": 1-10, "missing": "what's missing or empty string"}
        """

        let messages = [
            ChatMessage(role: "system", content: "Evaluate research answers. Output ONLY JSON."),
            ChatMessage(role: "user", content: prompt)
        ]

        let service = OpenAICompatibleService(provider: .deepseek, model: "deepseek-chat")
        guard let response = try? await service.sendChatRequest(messages: messages, tools: nil, maxTokens: 200),
              let text = response.text else {
            return EvaluationResult(passed: true, score: 0.7, feedback: "Could not evaluate.", shouldRetry: false)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"),
           let data = String(trimmed[start...end]).data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let rawScore = (parsed["score"] as? Double) ?? (parsed["score"] as? Int).map(Double.init) ?? 7.0
            let score = rawScore / 10.0
            let adequate = (parsed["adequate"] as? Bool) ?? (score >= 0.6)
            let missing = (parsed["missing"] as? String) ?? ""
            let feedback = missing.isEmpty ? "Research is adequate." : "Missing: \(missing)"
            return EvaluationResult(passed: adequate, score: score, feedback: feedback, shouldRetry: !adequate && score < 0.5)
        }

        return EvaluationResult(passed: true, score: 0.7, feedback: "Evaluation inconclusive.", shouldRetry: false)
    }
}
