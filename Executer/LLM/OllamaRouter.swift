import Foundation

/// Layer 1 local model router. Uses Ollama (Qwen2.5-3B or Phi-3 Mini) running locally
/// to classify requests and pick tools — completely free, no API calls.
/// Gracefully degrades: if Ollama isn't running, returns nil and existing routing takes over.
final class OllamaRouter {
    static let shared = OllamaRouter()

    struct RoutingResult: Codable {
        let tools: [String]
        let needsApi: Bool

        enum CodingKeys: String, CodingKey {
            case tools
            case needsApi = "needs_api"
        }
    }

    private let baseURL = "http://localhost:11434"
    private let model = "qwen2.5:3b"  // Small, fast, good enough for classification
    private let timeout: TimeInterval = 0.5  // 500ms — fail fast if Ollama isn't running

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }()

    private init() {}

    /// Check if Ollama is running locally.
    func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Route a user request through the local model.
    /// Returns nil if Ollama isn't available or routing fails (fall through to existing pipeline).
    func route(_ userInput: String) async -> RoutingResult? {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = buildRoutingPrompt(userInput)

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,    // Low temp for deterministic routing
                "num_predict": 100,    // Short response — just JSON
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            // Parse Ollama response
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else { return nil }

            // Extract JSON from response (model might include extra text)
            return parseRoutingResult(responseText)
        } catch {
            // Timeout, connection refused — silent fall-through
            return nil
        }
    }

    // MARK: - Private

    private func buildRoutingPrompt(_ input: String) -> String {
        """
        You are a tool router. Given a user request, identify which tools are needed and whether an API call is needed.

        Available tools:
        - app_launcher: opens/quits applications
        - music_controller: play/pause/skip music
        - volume_control: adjust system volume
        - brightness_control: adjust brightness
        - file_manager: read/write/move/find files
        - web_search: search the internet
        - web_navigator: open URLs in browser
        - screenshot: capture screen
        - clipboard: manage clipboard
        - notification: show notifications
        - timer: set timers and reminders
        - calendar: manage calendar events
        - system_settings: dark mode, wifi, bluetooth
        - deepseek_chat: complex reasoning, content generation
        - presentation_creator: make presentations
        - document_creator: make documents

        Recent successful routings:
        - "open Spotify" → {"tools": ["app_launcher"], "needs_api": false}
        - "make me a ppt about history" → {"tools": ["deepseek_chat", "presentation_creator"], "needs_api": true}
        - "what time is it" → {"tools": ["timer"], "needs_api": false}
        - "search for climate change" → {"tools": ["web_search"], "needs_api": false}
        - "help me write an essay" → {"tools": ["deepseek_chat"], "needs_api": true}
        - "set volume to 50" → {"tools": ["volume_control"], "needs_api": false}
        - "take a screenshot" → {"tools": ["screenshot"], "needs_api": false}

        Respond ONLY with JSON. No explanation.
        User request: "\(input)"
        """
    }

    private func parseRoutingResult(_ text: String) -> RoutingResult? {
        // Try to find JSON in the response (model might wrap it in text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try direct parse first
        if let data = trimmed.data(using: .utf8),
           let result = try? JSONDecoder().decode(RoutingResult.self, from: data) {
            return result
        }

        // Try to extract JSON from surrounding text
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            let jsonStr = String(trimmed[start...end])
            if let data = jsonStr.data(using: .utf8),
               let result = try? JSONDecoder().decode(RoutingResult.self, from: data) {
                return result
            }
        }

        return nil
    }
}
