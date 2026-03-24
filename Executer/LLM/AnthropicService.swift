import Foundation

// MARK: - Anthropic Messages API Adapter

class AnthropicService: LLMServiceProtocol {
    private let model: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let anthropicVersion = "2023-06-01"

    init(model: String) {
        self.model = model
    }

    func sendChatRequest(messages: [ChatMessage], tools: [[String: AnyCodable]]?, maxTokens: Int = 2048) async throws -> LLMResponse {
        guard let apiKey = APIKeyManager.shared.getKey(for: .claude) else {
            throw ExecuterError.apiError("No API key configured. Open Settings to enter your Claude API key.")
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // Convert OpenAI-format messages to Anthropic format
        let (systemPrompt, anthropicMessages) = convertMessages(messages)

        // Build request body
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": anthropicMessages
        ]

        if let system = systemPrompt {
            body["system"] = system
        }

        if let tools = tools {
            body["tools"] = convertToolDefinitions(tools)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try await URLSession.shared.data(for: request)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw ExecuterError.apiError("Invalid response")
        }

        guard http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw ExecuterError.apiError("Claude error: \(message)")
            }
            if errorText.contains("<html") || errorText.contains("<!DOCTYPE") {
                throw ExecuterError.apiError("Claude returned HTTP \(http.statusCode). The API endpoint may be down or unreachable.")
            }
            throw ExecuterError.apiError("Claude HTTP \(http.statusCode): \(String(errorText.prefix(200)))")
        }

        return try parseResponse(data)
    }

    // MARK: - Message Conversion (OpenAI → Anthropic)

    private func convertMessages(_ messages: [ChatMessage]) -> (system: String?, messages: [[String: Any]]) {
        var systemPrompt: String?
        var anthropicMessages: [[String: Any]] = []

        var i = 0
        while i < messages.count {
            let msg = messages[i]

            if msg.role == "system" {
                // Extract system messages as top-level param
                if let content = msg.content {
                    if let existing = systemPrompt {
                        systemPrompt = existing + "\n\n" + content
                    } else {
                        systemPrompt = content
                    }
                }
                i += 1
                continue
            }

            if msg.role == "assistant" {
                if let toolCalls = msg.tool_calls, !toolCalls.isEmpty {
                    // Assistant with tool_calls → content array with text + tool_use blocks
                    var contentArray: [[String: Any]] = []
                    if let text = msg.content, !text.isEmpty {
                        contentArray.append(["type": "text", "text": text])
                    }
                    for call in toolCalls {
                        var input: Any = [String: Any]()
                        if let data = call.function.arguments.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: data) {
                            input = parsed
                        }
                        contentArray.append([
                            "type": "tool_use",
                            "id": call.id,
                            "name": call.function.name,
                            "input": input
                        ])
                    }
                    anthropicMessages.append(["role": "assistant", "content": contentArray])
                } else {
                    anthropicMessages.append(["role": "assistant", "content": msg.content ?? ""])
                }
                i += 1
                continue
            }

            if msg.role == "tool" {
                // Batch consecutive tool messages into a single user message with tool_result blocks
                // (Anthropic rejects consecutive same-role messages)
                var toolResults: [[String: Any]] = []
                while i < messages.count && messages[i].role == "tool" {
                    let toolMsg = messages[i]
                    toolResults.append([
                        "type": "tool_result",
                        "tool_use_id": toolMsg.tool_call_id ?? "",
                        "content": toolMsg.content ?? ""
                    ])
                    i += 1
                }
                anthropicMessages.append(["role": "user", "content": toolResults])
                continue
            }

            // Regular user message
            anthropicMessages.append(["role": msg.role, "content": msg.content ?? ""])
            i += 1
        }

        return (systemPrompt, anthropicMessages)
    }

    // MARK: - Tool Definition Conversion (OpenAI → Anthropic)

    private func convertToolDefinitions(_ tools: [[String: AnyCodable]]) -> [[String: Any]] {
        return tools.compactMap { tool -> [String: Any]? in
            // OpenAI format: {type: "function", function: {name, description, parameters}}
            guard let funcWrapper = tool["function"],
                  let funcDict = funcWrapper.value as? [String: AnyCodable] else {
                return nil
            }

            let name = (funcDict["name"]?.value as? String) ?? ""
            let description = (funcDict["description"]?.value as? String) ?? ""
            let parameters = unwrapAnyCodable(funcDict["parameters"]?.value)

            var anthropicTool: [String: Any] = [
                "name": name,
                "description": description
            ]

            if let params = parameters as? [String: Any] {
                anthropicTool["input_schema"] = params
            } else {
                anthropicTool["input_schema"] = ["type": "object", "properties": [String: Any]()]
            }

            return anthropicTool
        }
    }

    /// Recursively unwrap AnyCodable wrappers to plain Swift types.
    private func unwrapAnyCodable(_ value: Any?) -> Any? {
        guard let value = value else { return nil }

        if let codable = value as? AnyCodable {
            return unwrapAnyCodable(codable.value)
        }
        if let dict = value as? [String: AnyCodable] {
            return dict.mapValues { unwrapAnyCodable($0.value) ?? NSNull() }
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { unwrapAnyCodable($0) ?? NSNull() }
        }
        if let arr = value as? [AnyCodable] {
            return arr.map { unwrapAnyCodable($0.value) ?? NSNull() }
        }
        if let arr = value as? [Any] {
            return arr.map { unwrapAnyCodable($0) ?? NSNull() }
        }
        return value
    }

    // MARK: - Response Parsing (Anthropic → LLMResponse with OpenAI-format rawMessage)

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]] else {
            throw ExecuterError.apiError("Invalid Anthropic response format")
        }

        var text: String?
        var toolCalls: [ToolCall] = []

        for block in contentArray {
            guard let type = block["type"] as? String else { continue }

            if type == "text", let t = block["text"] as? String {
                text = t
            } else if type == "tool_use" {
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                var arguments = "{}"
                if let input = block["input"] {
                    if let inputData = try? JSONSerialization.data(withJSONObject: input),
                       let inputStr = String(data: inputData, encoding: .utf8) {
                        arguments = inputStr
                    }
                }
                toolCalls.append(ToolCall(
                    id: id,
                    type: "function",
                    function: ToolCall.FunctionCall(name: name, arguments: arguments)
                ))
            }
        }

        // Construct rawMessage in OpenAI format so the agent loop can append it unchanged
        let rawMessage = ChatMessage(
            role: "assistant",
            content: text,
            tool_calls: toolCalls.isEmpty ? nil : toolCalls
        )

        return LLMResponse(
            text: text,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            rawMessage: rawMessage
        )
    }
}
