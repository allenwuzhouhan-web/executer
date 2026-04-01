import Foundation

// MARK: - Search Papers

struct SemanticScholarSearchTool: ToolDefinition {
    let name = "semantic_scholar_search"
    let description = "Search academic papers on Semantic Scholar. Returns titles, authors, year, citation count, and paper IDs."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Search query for academic papers"),
            "limit": JSONSchema.integer(description: "Number of results (default 5, max 20)"),
            "year": JSONSchema.string(description: "Filter by year or range (e.g. '2023', '2020-2024')"),
            "fields_of_study": JSONSchema.string(description: "Filter by field (e.g. 'Computer Science', 'Medicine', 'Physics')"),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let limit = min(optionalInt("limit", from: args) ?? 5, 20)
        let year = optionalString("year", from: args)
        let field = optionalString("fields_of_study", from: args)

        guard let apiKey = SemanticScholarKeyStore.getKey() else {
            return "No Semantic Scholar API key. Set one via set_semantic_scholar_key tool."
        }

        var components = URLComponents(string: "https://api.semanticscholar.org/graph/v1/paper/search")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: "title,authors,year,citationCount,abstract,url,externalIds"),
        ]
        if let year = year { queryItems.append(URLQueryItem(name: "year", value: year)) }
        if let field = field { queryItems.append(URLQueryItem(name: "fieldsOfStudy", value: field)) }
        components.queryItems = queryItems

        guard let url = components.url else { return "Invalid query." }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await PinnedURLSession.shared.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 { return "Rate limited. Try again in a moment." }
            if status == 401 { return "Invalid Semantic Scholar API key." }
            return "Semantic Scholar API error (HTTP \(status))."
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let papers = json["data"] as? [[String: Any]] else {
            return "No results found."
        }

        return formatPapers(papers)
    }

    private func formatPapers(_ papers: [[String: Any]]) -> String {
        if papers.isEmpty { return "No papers found." }
        var lines: [String] = ["Found \(papers.count) papers:\n"]
        for (i, paper) in papers.enumerated() {
            let title = paper["title"] as? String ?? "Untitled"
            let year = paper["year"] as? Int
            let citations = paper["citationCount"] as? Int ?? 0
            let authors = (paper["authors"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String }
                .prefix(3).joined(separator: ", ") ?? "Unknown"
            let paperId = paper["paperId"] as? String ?? ""
            let url = paper["url"] as? String ?? ""

            lines.append("\(i + 1). **\(title)** (\(year.map(String.init) ?? "n/a"))")
            lines.append("   Authors: \(authors)")
            lines.append("   Citations: \(citations) | ID: \(paperId)")
            if !url.isEmpty { lines.append("   URL: \(url)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Get Paper Details

struct GetPaperDetailsTool: ToolDefinition {
    let name = "get_paper_details"
    let description = "Get detailed information about a specific paper from Semantic Scholar, including abstract, references, and citations."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "paper_id": JSONSchema.string(description: "Semantic Scholar paper ID, DOI, or ArXiv ID (e.g. 'DOI:10.1234/...' or 'ArXiv:2301.00001')"),
        ], required: ["paper_id"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let paperId = try requiredString("paper_id", from: args)

        guard let apiKey = SemanticScholarKeyStore.getKey() else {
            return "No Semantic Scholar API key configured."
        }

        let fields = "title,authors,year,abstract,citationCount,referenceCount,influentialCitationCount,url,venue,publicationDate,externalIds,tldr"
        let encoded = paperId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? paperId
        let urlStr = "https://api.semanticscholar.org/graph/v1/paper/\(encoded)?fields=\(fields)"

        guard let url = URL(string: urlStr) else { return "Invalid paper ID." }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await PinnedURLSession.shared.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return "Paper not found." }
            return "Semantic Scholar API error (HTTP \(status))."
        }

        guard let paper = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Failed to parse paper data."
        }

        return formatPaperDetails(paper)
    }

    private func formatPaperDetails(_ paper: [String: Any]) -> String {
        let title = paper["title"] as? String ?? "Untitled"
        let year = paper["year"] as? Int
        let abstract = paper["abstract"] as? String
        let citations = paper["citationCount"] as? Int ?? 0
        let references = paper["referenceCount"] as? Int ?? 0
        let influential = paper["influentialCitationCount"] as? Int ?? 0
        let venue = paper["venue"] as? String
        let url = paper["url"] as? String
        let tldr = (paper["tldr"] as? [String: Any])?["text"] as? String
        let authors = (paper["authors"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String }
            .joined(separator: ", ") ?? "Unknown"

        var lines = [
            "**\(title)**",
            "Authors: \(authors)",
            "Year: \(year.map(String.init) ?? "n/a")",
        ]
        if let venue = venue, !venue.isEmpty { lines.append("Venue: \(venue)") }
        lines.append("Citations: \(citations) (influential: \(influential)) | References: \(references)")
        if let tldr = tldr { lines.append("\nTL;DR: \(tldr)") }
        if let abstract = abstract { lines.append("\nAbstract: \(abstract)") }
        if let url = url { lines.append("\n\(url)") }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Set API Key

struct SetSemanticScholarKeyTool: ToolDefinition {
    let name = "set_semantic_scholar_key"
    let description = "Set the Semantic Scholar API key for academic paper lookups."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "key": JSONSchema.string(description: "The Semantic Scholar API key")
        ], required: ["key"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let key = try requiredString("key", from: args)
        SemanticScholarKeyStore.setKey(key)
        return "Semantic Scholar API key saved."
    }
}

// MARK: - Key Store

enum SemanticScholarKeyStore {
    private static let keychainKey = "semantic_scholar_api_key"

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

    static func hasKey() -> Bool { getKey() != nil }
}
