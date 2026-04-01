import Foundation

/// Lightweight service for querying the DuckDuckGo Instant Answer API.
/// No API key required.
enum DuckDuckGoService {

    /// Queries DuckDuckGo for an instant answer.
    /// Returns nil on any failure (timeout, parse error, no result).
    static func query(_ text: String) async -> String? {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5

        guard let (data, _) = try? await PinnedURLSession.shared.session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Prefer AbstractText > Answer > first RelatedTopics text
        if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
            return abstract
        }
        if let answer = json["Answer"] as? String, !answer.isEmpty {
            return answer
        }
        if let topics = json["RelatedTopics"] as? [[String: Any]],
           let first = topics.first,
           let text = first["Text"] as? String, !text.isEmpty {
            return text
        }

        return nil
    }
}

// MARK: - Tool Definition

struct InstantSearchTool: ToolDefinition {
    let name = "instant_search"
    let description = "Search for instant answers, definitions, and factual information using DuckDuckGo. Returns concise answers without opening a browser."

    var parameters: [String: Any] {
        JSONSchema.object(
            properties: [
                "query": JSONSchema.string(description: "The search query to look up")
            ],
            required: ["query"]
        )
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)

        if let result = await DuckDuckGoService.query(query) {
            return result
        }
        return "No instant answer found."
    }
}
