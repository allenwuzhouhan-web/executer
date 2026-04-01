import Foundation

/// Tool: search_images — Searches for images online and returns URLs for use in document creation.
struct SearchImagesTool: ToolDefinition {
    let name = "search_images"
    let description = """
        Search for images online. Returns image URLs that can be used with create_presentation, \
        create_word_document, or create_spreadsheet via the image_url field. \
        Uses multiple search providers with automatic fallback.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Search terms for finding relevant images"),
            "count": JSONSchema.integer(description: "Number of results to return (1-20, default 5)"),
            "orientation": JSONSchema.string(description: "Preferred orientation: landscape (default for presentations), portrait, or any"),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let count = min(max(optionalInt("count", from: args) ?? 5, 1), 20)
        let orientation = optionalString("orientation", from: args) ?? "landscape"

        let results = await ImageSearchService.search(query: query, count: count, orientation: orientation)

        if results.isEmpty {
            return "No images found for \"\(query)\". Try different search terms or use browser_task to search Google Images directly."
        }

        // Format results as JSON
        let formatted = results.map { result -> [String: Any] in
            var dict: [String: Any] = [
                "url": result.url,
                "title": result.title,
                "source": result.source,
            ]
            if !result.thumbnail.isEmpty { dict["thumbnail"] = result.thumbnail }
            if result.width > 0 { dict["width"] = result.width }
            if result.height > 0 { dict["height"] = result.height }
            return dict
        }

        let response: [String: Any] = [
            "query": query,
            "count": formatted.count,
            "results": formatted,
            "usage_hint": "Use the 'url' field in image_url (PPT), image.url (Word), or images[].url (Excel) when creating documents.",
        ]

        if let data = try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Found \(formatted.count) images but failed to serialize results."
    }
}

// MARK: - Image Search Service

enum ImageSearchService {

    struct ImageResult {
        let url: String
        let thumbnail: String
        let title: String
        let width: Int
        let height: Int
        let source: String
    }

    // In-memory cache: query → (results, timestamp). Protected by serial queue.
    private static let cacheQueue = DispatchQueue(label: "com.executer.imageSearchCache")
    private static var _cache: [String: ([ImageResult], Date)] = [:]
    private static let cacheTTL: TimeInterval = 1800 // 30 minutes

    private static func getCached(_ key: String) -> [ImageResult]? {
        cacheQueue.sync {
            if let (results, timestamp) = _cache[key], Date().timeIntervalSince(timestamp) < cacheTTL {
                return results
            }
            return nil
        }
    }

    private static func setCache(_ key: String, results: [ImageResult]) {
        cacheQueue.sync { _cache[key] = (results, Date()) }
    }

    /// Search for images using a multi-provider fallback chain.
    static func search(query: String, count: Int, orientation: String = "landscape") async -> [ImageResult] {
        let cacheKey = "\(query)|\(count)|\(orientation)"
        if let cached = getCached(cacheKey) {
            return cached
        }

        // Tier 1: DuckDuckGo image search
        var results = await searchDuckDuckGo(query: query, count: count + 10) // fetch extra for filtering

        // Tier 2: Unsplash (if DDG fails or returns too few)
        if results.count < count {
            let unsplashResults = await searchUnsplash(query: query, count: count + 5)
            results.append(contentsOf: unsplashResults)
        }

        // Filter and rank
        var filtered = filterResults(results, orientation: orientation)

        // Deduplicate by URL
        var seen = Set<String>()
        filtered = filtered.filter { seen.insert($0.url).inserted }

        // Limit to requested count
        let final = Array(filtered.prefix(count))
        setCache(cacheKey, results: final)
        return final
    }

    // MARK: - Filtering

    private static func filterResults(_ results: [ImageResult], orientation: String) -> [ImageResult] {
        var filtered = results.filter { result in
            // Filter out known low-quality sources
            let url = result.url.lowercased()
            let junkDomains = ["placeholder.com", "dummyimage.com", "via.placeholder", "placehold.it"]
            if junkDomains.contains(where: { url.contains($0) }) { return false }

            // Minimum resolution
            if result.width > 0 && result.height > 0 {
                if result.width < 400 || result.height < 300 { return false }
            }

            return true
        }

        // Sort by orientation preference
        if orientation == "landscape" {
            filtered.sort { a, b in
                let aRatio = a.width > 0 && a.height > 0 ? Double(a.width) / Double(a.height) : 1.5
                let bRatio = b.width > 0 && b.height > 0 ? Double(b.width) / Double(b.height) : 1.5
                // Prefer landscape (ratio > 1.2), then by resolution
                let aIsLandscape = aRatio > 1.2
                let bIsLandscape = bRatio > 1.2
                if aIsLandscape != bIsLandscape { return aIsLandscape }
                return (a.width * a.height) > (b.width * b.height)
            }
        } else if orientation == "portrait" {
            filtered.sort { a, b in
                let aRatio = a.width > 0 && a.height > 0 ? Double(a.width) / Double(a.height) : 1.5
                let bRatio = b.width > 0 && b.height > 0 ? Double(b.width) / Double(b.height) : 1.5
                let aIsPortrait = aRatio < 0.85
                let bIsPortrait = bRatio < 0.85
                if aIsPortrait != bIsPortrait { return aIsPortrait }
                return (a.width * a.height) > (b.width * b.height)
            }
        }

        return filtered
    }

    // MARK: - DuckDuckGo Provider

    private static func searchDuckDuckGo(query: String, count: Int) async -> [ImageResult] {
        guard let token = await getDDGToken(query: query) else { return [] }
        return await fetchDDGImages(query: query, token: token, count: count)
    }

    private static func getDDGToken(query: String) async -> String? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://duckduckgo.com/?q=\(encoded)&iax=images&ia=images")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await PinnedURLSession.shared.session.data(for: request),
              let html = String(data: data, encoding: .utf8)
        else { return nil }

        // Multiple token extraction patterns for robustness
        let patterns = [
            #"vqd="([^"]+)""#,
            #"vqd='([^']+)'"#,
            #"vqd=([\d]+-[\w]+)"#,
            #"vqd%3D([\d]+-[\w]+)"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range])
            }
        }
        return nil
    }

    private static func fetchDDGImages(query: String, token: String, count: Int) async -> [ImageResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://duckduckgo.com/i.js?l=us-en&o=json&q=\(encoded)&vqd=\(token)&f=,,,,,&p=1")
        else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://duckduckgo.com", forHTTPHeaderField: "Referer")

        guard let (data, _) = try? await PinnedURLSession.shared.session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return [] }

        return results.prefix(count).compactMap { item -> ImageResult? in
            guard let imageURL = item["image"] as? String, !imageURL.isEmpty else { return nil }
            return ImageResult(
                url: imageURL,
                thumbnail: (item["thumbnail"] as? String) ?? "",
                title: (item["title"] as? String) ?? "",
                width: (item["width"] as? Int) ?? 0,
                height: (item["height"] as? Int) ?? 0,
                source: (item["source"] as? String) ?? ""
            )
        }
    }

    // MARK: - Unsplash Provider (public endpoint, no key needed)

    private static func searchUnsplash(query: String, count: Int) async -> [ImageResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://unsplash.com/napi/search/photos?query=\(encoded)&per_page=\(count)")
        else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://unsplash.com", forHTTPHeaderField: "Referer")

        guard let (data, _) = try? await PinnedURLSession.shared.session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return [] }

        return results.prefix(count).compactMap { item -> ImageResult? in
            guard let urls = item["urls"] as? [String: String],
                  let regularURL = urls["regular"] ?? urls["small"]
            else { return nil }

            let desc = (item["description"] as? String) ?? (item["alt_description"] as? String) ?? ""
            let w = item["width"] as? Int ?? 0
            let h = item["height"] as? Int ?? 0
            let user = (item["user"] as? [String: Any])?["name"] as? String ?? "Unsplash"

            return ImageResult(
                url: regularURL,
                thumbnail: urls["thumb"] ?? urls["small"] ?? regularURL,
                title: desc,
                width: w,
                height: h,
                source: "unsplash.com/\(user)"
            )
        }
    }
}
