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

    init(role: String, content: String?, tool_calls: [ToolCall]? = nil, tool_call_id: String? = nil, reasoning_content: String? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.reasoning_content = reasoning_content
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
    }

    struct Usage: Codable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
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

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body = ChatCompletionRequest(
            model: model,
            messages: messages,
            tools: tools,
            tool_choice: tools != nil ? "auto" : nil,
            max_tokens: maxTokens,
            stream: false
        )

        request.httpBody = try sharedJSONEncoder.encode(body)

        let (data, httpResponse) = try await URLSession.shared.data(for: request)

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
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? "unreadable"
            if preview.contains("<html") || preview.contains("<!DOCTYPE") {
                throw ExecuterError.apiError("\(provider.config.displayName) returned HTML instead of JSON. The API endpoint may be misconfigured or down.")
            }
            throw ExecuterError.apiError("\(provider.config.displayName) response parse error: \(error.localizedDescription)")
        }

        guard let choice = decoded.choices.first else {
            throw ExecuterError.apiError("No response choices")
        }

        return LLMResponse(
            text: choice.message.content,
            toolCalls: choice.message.tool_calls,
            rawMessage: choice.message
        )
    }
}
