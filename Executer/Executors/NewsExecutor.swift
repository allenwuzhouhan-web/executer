import Foundation

// MARK: - API Key Store

enum NewsKeyStore {
    private static let keychainKey = "newsapi_api_key"

    static func getKey() -> String? {
        guard let data = KeychainHelper.load(key: keychainKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        _ = KeychainHelper.save(key: keychainKey, data: data)
    }

    static func delete() {
        KeychainHelper.delete(key: keychainKey)
    }

    static func hasKey() -> Bool {
        getKey() != nil
    }
}

// MARK: - News Data Model

struct NewsArticle {
    let source: String
    let title: String
    let description: String?
    let url: String
    let publishedAt: String
}

// MARK: - Fetch Headlines Tool

struct FetchNewsTool: ToolDefinition {
    let name = "fetch_news"
    let description = "Fetch top news headlines from NewsAPI. Returns titles, sources, and short descriptions. Optionally filter by category or search query."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "category": JSONSchema.enumString(
                description: "News category (default: general)",
                values: ["general", "business", "technology", "science", "health", "sports", "entertainment"]
            ),
            "query": JSONSchema.string(description: "Optional search query to filter headlines"),
            "country": JSONSchema.string(description: "2-letter country code (default: us)"),
            "count": JSONSchema.integer(description: "Number of articles to return (default: 10, max: 20)", minimum: 1, maximum: 20)
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let category = optionalString("category", from: args) ?? "general"
        let query = optionalString("query", from: args)
        let country = optionalString("country", from: args) ?? "us"
        let count = optionalInt("count", from: args) ?? 10

        guard let apiKey = NewsKeyStore.getKey() else {
            return "No NewsAPI key configured. Set one with the set_news_key tool."
        }

        let articles = try await fetchHeadlines(
            apiKey: apiKey, category: category, query: query,
            country: country, count: min(count, 20)
        )

        if articles.isEmpty {
            return "No headlines found for category '\(category)'\(query.map { " matching '\($0)'" } ?? "")."
        }

        var lines: [String] = ["**Top Headlines** (\(category.capitalized))"]
        lines.append("")
        for (i, article) in articles.enumerated() {
            lines.append("**\(i + 1). \(article.title)**")
            lines.append("   _\(article.source)_")
            if let desc = article.description, !desc.isEmpty {
                let trimmed = String(desc.prefix(200))
                lines.append("   \(trimmed)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func fetchHeadlines(apiKey: String, category: String, query: String?, country: String, count: Int) async throws -> [NewsArticle] {
        var components = URLComponents(string: "https://newsapi.org/v2/top-headlines")!
        var queryItems = [
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "pageSize", value: String(count)),
            URLQueryItem(name: "apiKey", value: apiKey)
        ]
        if let q = query, !q.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: q))
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw ExecuterError.apiError("Invalid news URL") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, response) = try await PinnedURLSession.shared.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { throw ExecuterError.apiError("Invalid NewsAPI key.") }
            throw ExecuterError.apiError("NewsAPI error (HTTP \(status)).")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawArticles = json["articles"] as? [[String: Any]] else {
            throw ExecuterError.apiError("Failed to parse news response.")
        }

        return rawArticles.compactMap { raw in
            guard let title = raw["title"] as? String, !title.isEmpty else { return nil }
            let sourceName = (raw["source"] as? [String: Any])?["name"] as? String ?? "Unknown"
            let desc = raw["description"] as? String
            let url = raw["url"] as? String ?? ""
            let published = raw["publishedAt"] as? String ?? ""
            return NewsArticle(source: sourceName, title: title, description: desc, url: url, publishedAt: published)
        }
    }
}

// MARK: - Set News API Key Tool

struct SetNewsKeyTool: ToolDefinition {
    let name = "set_news_key"
    let description = "Save a NewsAPI.org API key for fetching news headlines."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "key": JSONSchema.string(description: "The NewsAPI.org API key")
        ], required: ["key"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let key = try requiredString("key", from: args)
        NewsKeyStore.setKey(key)
        return "NewsAPI key saved."
    }
}
