import Foundation

extension LocalCommandRouter {

    func tryWebNavigation(_ input: String) async -> String? {
        // "go to [url]" / "navigate to [url]" / "open [url]"
        let navPrefixes = ["go to ", "navigate to ", "open "]
        for prefix in navPrefixes {
            if input.hasPrefix(prefix) {
                var target = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Try full target first (e.g., "open google.com/maps")
                if let url = resolveURL(target) {
                    let jsonArg = "{\"url\": \"\(escapeJSON(url))\"}"
                    return try? await OpenInSafariTool().execute(arguments: jsonArg)
                }
                // If target has " and " or " then ", extract just the first part
                // e.g., "open youtube and search for X" → try "youtube" alone for plain navigation
                for sep in [" and ", " then "] {
                    if let range = target.range(of: sep) {
                        let firstPart = String(target[target.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                        if let url = resolveURL(firstPart) {
                            // Don't navigate here — let tryCompoundOpenAndSearch handle compound commands
                            break
                        }
                    }
                }
            }
        }

        // "[url] in safari" / "open [url] in safari"
        if input.contains(" in safari") {
            let target = input.replacingOccurrences(of: " in safari", with: "")
                .replacingOccurrences(of: "open ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = resolveURL(target) {
                let jsonArg = "{\"url\": \"\(escapeJSON(url))\"}"
                return try? await OpenInSafariTool().execute(arguments: jsonArg)
            }
        }

        // "new tab [url]" / "new tab with [url]"
        if input.hasPrefix("new tab ") {
            let target = input.replacingOccurrences(of: "new tab with ", with: "")
                .replacingOccurrences(of: "new tab ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = resolveURL(target) {
                let jsonArg = "{\"url\": \"\(escapeJSON(url))\"}"
                return try? await NewSafariTabTool().execute(arguments: jsonArg)
            }
        }

        return nil
    }

    func trySearchCommand(_ input: String) async -> String? {
        // "open youtube and search for [query]" / "go to youtube and search [query]"
        // Catches compound "open/go to [platform] and search/look up/find [query]" commands
        if let result = await tryCompoundOpenAndSearch(input) {
            return result
        }

        // "search youtube for [query]" / "youtube [query]" / "search [query] on youtube"
        if let query = extractSearchQuery(input, platform: "youtube") {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let url = "https://www.youtube.com/results?search_query=\(encoded)"
            return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
        }

        // "search google for [query]" / "google [query]"
        if let query = extractSearchQuery(input, platform: "google") {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            return try? await SearchWebTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\"}")
        }

        // "search for [query]" / "look up [query]" / "search [query]"
        let searchPrefixes = ["search for ", "look up ", "search "]
        for prefix in searchPrefixes {
            if input.hasPrefix(prefix) {
                let query = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Don't match "search youtube/google" — those are handled above
                if !query.isEmpty && !query.hasPrefix("youtube") && !query.hasPrefix("google") &&
                   !query.contains(" on youtube") && !query.contains(" on google") {
                    return try? await SearchWebTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\"}")
                }
            }
        }

        // "search [query] on [platform]"
        if input.hasPrefix("search ") && input.contains(" on ") {
            let afterSearch = String(input.dropFirst("search ".count))
            if let onRange = afterSearch.range(of: " on ", options: .backwards) {
                let query = String(afterSearch[afterSearch.startIndex..<onRange.lowerBound])
                let platform = String(afterSearch[onRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

                if !query.isEmpty {
                    if let url = searchURLForPlatform(platform, query: query) {
                        return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
                    }
                }
            }
        }

        // "watch [query]" — assume YouTube
        if input.hasPrefix("watch ") {
            let query = String(input.dropFirst("watch ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                let url = "https://www.youtube.com/results?search_query=\(encoded)"
                return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
            }
        }

        return nil
    }

    // MARK: - URL Resolution

    /// Tries to resolve a spoken/typed target into a valid URL.
    func resolveURL(_ target: String) -> String? {
        let clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // Already a URL
        if clean.hasPrefix("http://") || clean.hasPrefix("https://") {
            return clean
        }

        // Looks like a domain (contains a dot, no spaces)
        if clean.contains(".") && !clean.contains(" ") {
            return "https://\(clean)"
        }

        // Common site shortcuts — static to avoid 40+ allocations per call
        return Self.siteShortcuts[clean]
    }

    // Cached outside resolveURL to avoid re-creating 40-entry dict on every call
    private static let siteShortcuts: [String: String] = [
            "youtube": "https://www.youtube.com",
            "google": "https://www.google.com",
            "gmail": "https://mail.google.com",
            "twitter": "https://x.com",
            "x": "https://x.com",
            "reddit": "https://www.reddit.com",
            "github": "https://github.com",
            "facebook": "https://www.facebook.com",
            "instagram": "https://www.instagram.com",
            "linkedin": "https://www.linkedin.com",
            "amazon": "https://www.amazon.com",
            "netflix": "https://www.netflix.com",
            "spotify": "https://open.spotify.com",
            "twitch": "https://www.twitch.tv",
            "discord": "https://discord.com/app",
            "slack": "https://app.slack.com",
            "notion": "https://www.notion.so",
            "figma": "https://www.figma.com",
            "chatgpt": "https://chat.openai.com",
            "claude": "https://claude.ai",
            "hacker news": "https://news.ycombinator.com",
            "hackernews": "https://news.ycombinator.com",
            "hn": "https://news.ycombinator.com",
            "stack overflow": "https://stackoverflow.com",
            "stackoverflow": "https://stackoverflow.com",
            "wikipedia": "https://en.wikipedia.org",
            "maps": "https://maps.google.com",
            "google maps": "https://maps.google.com",
            "google drive": "https://drive.google.com",
            "drive": "https://drive.google.com",
            "docs": "https://docs.google.com",
            "google docs": "https://docs.google.com",
            "sheets": "https://sheets.google.com",
            "google sheets": "https://sheets.google.com",
            "calendar": "https://calendar.google.com",
            "google calendar": "https://calendar.google.com",
            "whatsapp": "https://web.whatsapp.com",
            "telegram": "https://web.telegram.org",
            "tiktok": "https://www.tiktok.com",
            "pinterest": "https://www.pinterest.com",
            "ebay": "https://www.ebay.com",
            "apple music": "https://music.apple.com",
        ]

    // MARK: - Search Query Extraction

    /// Extract search query for a specific platform from various natural phrasings.
    func extractSearchQuery(_ input: String, platform: String) -> String? {
        // "search [platform] for [query]"
        if input.hasPrefix("search \(platform) for ") {
            let query = String(input.dropFirst("search \(platform) for ".count))
            return query.isEmpty ? nil : query
        }

        // "search for [query] on [platform]"
        if input.hasPrefix("search for ") && input.hasSuffix(" on \(platform)") {
            let withoutPrefix = String(input.dropFirst("search for ".count))
            let query = String(withoutPrefix.dropLast(" on \(platform)".count))
            return query.isEmpty ? nil : query
        }

        // "search [query] on [platform]"
        if input.hasPrefix("search ") && input.hasSuffix(" on \(platform)") {
            let withoutPrefix = String(input.dropFirst("search ".count))
            let query = String(withoutPrefix.dropLast(" on \(platform)".count))
            return query.isEmpty ? nil : query
        }

        // "[platform] [query]" (e.g., "youtube funny cats")
        if input.hasPrefix("\(platform) ") {
            let query = String(input.dropFirst("\(platform) ".count))
            return query.isEmpty ? nil : query
        }

        // "[query] on [platform]"
        if input.hasSuffix(" on \(platform)") {
            let query = String(input.dropLast(" on \(platform)".count))
            // Filter out things that don't look like search queries
            if !query.isEmpty && !query.hasPrefix("search") && !query.hasPrefix("look") {
                return query
            }
        }

        // "find [query] on [platform]"
        if input.hasPrefix("find ") && input.hasSuffix(" on \(platform)") {
            let withoutPrefix = String(input.dropFirst("find ".count))
            let query = String(withoutPrefix.dropLast(" on \(platform)".count))
            return query.isEmpty ? nil : query
        }

        return nil
    }

    /// Build a search URL for a given platform.
    func searchURLForPlatform(_ platform: String, query: String) -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch platform.lowercased() {
        case "youtube":
            return "https://www.youtube.com/results?search_query=\(encoded)"
        case "google":
            return "https://www.google.com/search?q=\(encoded)"
        case "reddit":
            return "https://www.reddit.com/search/?q=\(encoded)"
        case "amazon":
            return "https://www.amazon.com/s?k=\(encoded)"
        case "github":
            return "https://github.com/search?q=\(encoded)"
        case "twitter", "x":
            return "https://x.com/search?q=\(encoded)"
        case "wikipedia":
            return "https://en.wikipedia.org/w/index.php?search=\(encoded)"
        case "stack overflow", "stackoverflow":
            return "https://stackoverflow.com/search?q=\(encoded)"
        case "spotify":
            return "https://open.spotify.com/search/\(encoded)"
        default:
            return nil
        }
    }

    // MARK: - Compound "open X and search for Y"

    /// Handles "open youtube and search for how claw works", "go to reddit and look up swift concurrency", etc.
    private func tryCompoundOpenAndSearch(_ input: String) async -> String? {
        // Match: (open|go to) [platform] and (search for|search|look up|find) [query]
        let openPrefixes = ["open ", "go to "]
        let searchSeparators = [" and search for ", " and search ", " and look up ", " and find "]

        for prefix in openPrefixes {
            guard input.hasPrefix(prefix) else { continue }
            let afterPrefix = String(input.dropFirst(prefix.count))

            for sep in searchSeparators {
                guard let sepRange = afterPrefix.range(of: sep) else { continue }
                let platform = String(afterPrefix[afterPrefix.startIndex..<sepRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let query = String(afterPrefix[sepRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)

                guard !platform.isEmpty, !query.isEmpty else { continue }

                // Try to build a search URL for this platform
                if let url = searchURLForPlatform(platform, query: query) {
                    return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
                }

                // If it's a known site but without search URL support, open the site + google search
                if Self.siteShortcuts[platform] != nil {
                    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                    let url = "https://www.google.com/search?q=\(encoded)+site:\(platform).com"
                    return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
                }
            }
        }

        return nil
    }
}
