import Foundation

// Cached JSON coders — avoid re-creating per API call (~0.3ms each)
private let sharedJSONEncoder = JSONEncoder()
private let sharedJSONDecoder = JSONDecoder()

// MARK: - API Types (OpenAI-compatible format)

struct ChatMessage: Codable {
    let role: String
    let content: String?
    let tool_calls: [ToolCall]?
    let tool_call_id: String?
    let reasoning_content: String?

    /// Multimodal content blocks for vision LLMs (text + image).
    /// When set, AnthropicService uses these instead of plain `content`.
    /// Not serialized — only used for in-memory message passing.
    var contentBlocks: [[String: Any]]?

    init(role: String, content: String?, tool_calls: [ToolCall]? = nil, tool_call_id: String? = nil, reasoning_content: String? = nil, contentBlocks: [[String: Any]]? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.reasoning_content = reasoning_content
        self.contentBlocks = contentBlocks
    }

    // Custom decoder: tolerate unknown fields, missing optional fields, and type mismatches.
    // Different APIs (DeepSeek, Kimi, Gemini, MiniMax) return slightly different JSON.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)

        // content can be String or null or missing entirely
        content = try? container.decodeIfPresent(String.self, forKey: .content)

        // tool_calls: try to decode, silently ignore if format doesn't match
        tool_calls = try? container.decodeIfPresent([ToolCall].self, forKey: .tool_calls)

        // tool_call_id: only present in tool-result messages
        tool_call_id = try? container.decodeIfPresent(String.self, forKey: .tool_call_id)

        // reasoning_content: DeepSeek-specific, other APIs won't have it
        reasoning_content = try? container.decodeIfPresent(String.self, forKey: .reasoning_content)

        // contentBlocks is not serialized — only used in-memory
        contentBlocks = nil
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, tool_calls, tool_call_id, reasoning_content
    }
}

struct ToolCall: Codable {
    let id: String
    let type: String
    let function: FunctionCall

    struct FunctionCall: Codable {
        let name: String
        let arguments: String
    }

    // Tolerate missing/extra fields from different APIs
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        type = (try? container.decode(String.self, forKey: .type)) ?? "function"
        function = try container.decode(FunctionCall.self, forKey: .function)
    }

    init(id: String, type: String, function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, function
    }
}

struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let tools: [[String: AnyCodable]]?
    let tool_choice: String?
    let max_tokens: Int?
    let stream: Bool?
}

struct ChatCompletionResponse: Codable {
    let id: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Codable {
        let index: Int
        let message: ChatMessage
        let finish_reason: String?

        // Tolerate missing index (some APIs omit it)
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = (try? container.decodeIfPresent(Int.self, forKey: .index)) ?? 0
            message = try container.decode(ChatMessage.self, forKey: .message)
            finish_reason = try? container.decodeIfPresent(String.self, forKey: .finish_reason)
        }
        private enum CodingKeys: String, CodingKey { case index, message, finish_reason }
    }

    struct Usage: Codable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int

        // Tolerate missing fields (some APIs use different names)
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prompt_tokens = (try? container.decode(Int.self, forKey: .prompt_tokens)) ?? 0
            completion_tokens = (try? container.decode(Int.self, forKey: .completion_tokens)) ?? 0
            total_tokens = (try? container.decode(Int.self, forKey: .total_tokens)) ?? 0
        }
        private enum CodingKeys: String, CodingKey { case prompt_tokens, completion_tokens, total_tokens }
    }
}

// MARK: - AnyCodable helper for JSON Schema

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { value = str }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict }
        else if let arr = try? container.decode([AnyCodable].self) { value = arr }
        else if container.decodeNil() { value = NSNull() }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let str as String: try container.encode(str)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        case let dict as [String: AnyCodable]: try container.encode(dict)
        case let dict as [String: Any]: try container.encode(dict.mapValues { AnyCodable($0) })
        case let arr as [AnyCodable]: try container.encode(arr)
        case let arr as [Any]: try container.encode(arr.map { AnyCodable($0) })
        case is NSNull: try container.encodeNil()
        default: try container.encodeNil()
        }
    }
}

// MARK: - Response wrapper

struct LLMResponse {
    let text: String?
    let toolCalls: [ToolCall]?
    let rawMessage: ChatMessage
}

// MARK: - OpenAI-Compatible Service (DeepSeek, Gemini, Kimi, MiniMax)

class OpenAICompatibleService: LLMServiceProtocol {
    private let provider: LLMProvider
    private let model: String
    private let baseURL: String

    init(provider: LLMProvider, model: String) {
        self.provider = provider
        self.model = model
        self.baseURL = provider.config.baseURL
    }

    func sendChatRequest(messages: [ChatMessage], tools: [[String: AnyCodable]]?, maxTokens: Int = 2048) async throws -> LLMResponse {
        guard let apiKey = APIKeyManager.shared.getKey(for: provider) else {
            throw ExecuterError.apiError("No API key configured. Open Settings to enter your \(provider.config.displayName) API key.")
        }

        guard let url = URL(string: baseURL) else {
            throw ExecuterError.apiError("Invalid API URL for \(provider.config.displayName).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // Kimi Coding endpoint requires a coding-agent User-Agent to allow access
        if provider == .kimiCN || provider == .kimi {
            request.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
        }

        let body = ChatCompletionRequest(
            model: model,
            messages: messages,
            tools: tools,
            tool_choice: tools != nil ? "auto" : nil,
            max_tokens: maxTokens,
            stream: false
        )

        request.httpBody = try sharedJSONEncoder.encode(body)

        let (data, httpResponse) = try await PinnedURLSession.shared.session.data(for: request)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw ExecuterError.apiError("Invalid response")
        }

        guard http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            // Try to extract a clean error message from JSON error responses
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                var hint = ""
                if (provider == .kimi || provider == .kimiCN) && (http.statusCode == 401 || http.statusCode == 403) {
                    hint = " (Note: Kimi keys from platform.moonshot.cn won't work with the .ai endpoint, and vice versa. Use the matching provider.)"
                }
                throw ExecuterError.apiError("\(provider.config.displayName) error: \(message)\(hint)")
            }
            // If it's HTML (common when endpoint is wrong or server error), show a clean message
            if errorText.contains("<html") || errorText.contains("<!DOCTYPE") || errorText.contains("<HTML") {
                throw ExecuterError.apiError("\(provider.config.displayName) returned HTTP \(http.statusCode). The API endpoint may be down or unreachable. Check your API key and try again.")
            }
            throw ExecuterError.apiError("\(provider.config.displayName) HTTP \(http.statusCode): \(String(errorText.prefix(200)))")
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try sharedJSONDecoder.decode(ChatCompletionResponse.self, from: data)
        } catch {
            let preview = String(data: data, encoding: .utf8)?.prefix(500) ?? "unreadable"
            if preview.contains("<html") || preview.contains("<!DOCTYPE") {
                throw ExecuterError.apiError("\(provider.config.displayName) returned HTML instead of JSON. The API endpoint may be misconfigured or down.")
            }
            // Log the actual response for debugging
            print("[API] \(provider.config.displayName) parse failure. Raw response: \(preview)")
            print("[API] Decode error: \(error)")
            throw ExecuterError.apiError("\(provider.config.displayName) response parse error: \(error.localizedDescription)")
        }

        guard let choice = decoded.choices.first else {
            throw ExecuterError.apiError("No response choices")
        }

        // Track API usage for cost budgeting
        if let usage = decoded.usage {
            CostTracker.shared.record(
                provider: provider.rawValue,
                inputTokens: usage.prompt_tokens,
                outputTokens: usage.completion_tokens,
                agentId: CostTracker.shared.activeAgentId
            )
        }

        // Use content if available; fall back to reasoning_content for thinking models (DeepSeek-R1, Kimi)
        let text = (choice.message.content?.isEmpty == false ? choice.message.content : nil)
            ?? choice.message.reasoning_content

        return LLMResponse(
            text: text,
            toolCalls: choice.message.tool_calls,
            rawMessage: choice.message
        )
    }

    func streamChatRequest(messages: [ChatMessage], tools: [[String: AnyCodable]]?, maxTokens: Int) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { [self] continuation in
            Task {
                do {
                    guard let apiKey = APIKeyManager.shared.getKey(for: provider) else {
                        continuation.finish(throwing: ExecuterError.apiError("No API key configured for \(provider.config.displayName)."))
                        return
                    }
                    guard let url = URL(string: provider.config.baseURL) else {
                        continuation.finish(throwing: ExecuterError.apiError("Invalid API URL for \(provider.config.displayName)."))
                        return
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 120
                    if provider == .kimiCN || provider == .kimi {
                        request.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
                    }

                    let body = ChatCompletionRequest(
                        model: model,
                        messages: messages,
                        tools: tools?.isEmpty == true ? nil : tools,
                        tool_choice: tools != nil ? "auto" : nil,
                        max_tokens: maxTokens,
                        stream: true
                    )
                    request.httpBody = try sharedJSONEncoder.encode(body)

                    let (bytes, httpResponse) = try await PinnedURLSession.shared.session.bytes(for: request)

                    guard let http = httpResponse as? HTTPURLResponse, http.statusCode == 200 else {
                        throw ExecuterError.apiError("Stream request failed with HTTP \((httpResponse as? HTTPURLResponse)?.statusCode ?? 0)")
                    }

                    var accumulatedText = ""
                    var toolCallAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        if json == "[DONE]" { break }

                        guard let data = json.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = chunk["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }

                        // Text content delta
                        if let content = delta["content"] as? String {
                            accumulatedText += content
                            continuation.yield(.textDelta(content))
                        }

                        // Tool call deltas
                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for tc in toolCalls {
                                guard let index = tc["index"] as? Int else { continue }
                                let function = tc["function"] as? [String: Any]

                                if let id = tc["id"] as? String, let name = function?["name"] as? String {
                                    toolCallAccumulators[index] = (id: id, name: name, arguments: "")
                                    continuation.yield(.toolCallStart(id: id, name: name))
                                }

                                if let argDelta = function?["arguments"] as? String {
                                    toolCallAccumulators[index]?.arguments += argDelta
                                    if let id = toolCallAccumulators[index]?.id {
                                        continuation.yield(.toolCallDelta(id: id, argumentsDelta: argDelta))
                                    }
                                }
                            }
                        }
                    }

                    // Build final response
                    let finalToolCalls: [ToolCall]? = toolCallAccumulators.isEmpty ? nil : toolCallAccumulators.sorted(by: { $0.key < $1.key }).map { (_, acc) in
                        ToolCall(id: acc.id, type: "function", function: ToolCall.FunctionCall(name: acc.name, arguments: acc.arguments))
                    }

                    let rawMessage = ChatMessage(
                        role: "assistant",
                        content: accumulatedText.isEmpty ? nil : accumulatedText,
                        tool_calls: finalToolCalls
                    )
                    let response = LLMResponse(text: accumulatedText.isEmpty ? nil : accumulatedText, toolCalls: finalToolCalls, rawMessage: rawMessage)
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
