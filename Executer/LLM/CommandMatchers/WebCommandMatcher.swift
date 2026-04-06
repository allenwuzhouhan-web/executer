import Foundation

extension LocalCommandRouter {

    func tryWebNavigation(_ input: String) async -> String? {
        // "go to [url]" / "navigate to [url]" / "open [url]"
        let navPrefixes = ["go to ", "navigate to ", "open "]
        for prefix in navPrefixes {
            if input.hasPrefix(prefix) {
                let target = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Try full target first (e.g., "open google.com/maps")
                if let url = resolveURL(target) {
                    let jsonArg = "{\"url\": \"\(escapeJSON(url))\"}"
                    return try? await OpenInSafariTool().execute(arguments: jsonArg)
                }
                // If target has " and " or " then ", don't navigate — let tryCompoundOpenAndSearch handle it
                for sep in [" and ", " then "] {
                    if target.range(of: sep) != nil {
                        break
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
        // "open youtube and search for [query]" / "go to reddit.com and look up [query]"
        if let result = await tryCompoundOpenAndSearch(input) {
            return result
        }

        // "search youtube for [query]" / "search youtube.com for [query]"
        if let result = await tryPlatformSearch(input) {
            return result
        }

        // "search for [query]" / "look up [query]" / "search [query]" → Google
        let searchPrefixes = ["search for ", "look up ", "search "]
        for prefix in searchPrefixes {
            if input.hasPrefix(prefix) {
                let query = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { continue }
                // Skip if it's "[platform] for [query]" or "[query] on [platform]" — handled elsewhere
                if query.contains(" on ") || query.contains(" for ") { continue }
                // Skip if first word is a resolvable site name
                let firstWord = String(query.split(separator: " ").first ?? "")
                if resolveURL(firstWord) != nil && query.split(separator: " ").count > 1 { continue }
                return try? await SearchWebTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\"}")
            }
        }

        // "search [query] on [platform]" / "search cats on youtube.com"
        if input.hasPrefix("search ") && input.contains(" on ") {
            let afterSearch = String(input.dropFirst("search ".count))
            if let onRange = afterSearch.range(of: " on ", options: .backwards) {
                let query = String(afterSearch[afterSearch.startIndex..<onRange.lowerBound])
                let rawPlatform = String(afterSearch[onRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty {
                    return try? await openSearchURL(platform: rawPlatform, query: query)
                }
            }
        }

        // "[query] on [platform]" — "funny cats on youtube" / "headphones on amazon"
        if input.contains(" on ") {
            if let onRange = input.range(of: " on ", options: .backwards) {
                let query = String(input[input.startIndex..<onRange.lowerBound])
                let rawPlatform = String(input[onRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                // Only match if the suffix resolves to a known site
                if !query.isEmpty && resolveURL(rawPlatform) != nil {
                    return try? await openSearchURL(platform: rawPlatform, query: query)
                }
            }
        }

        // "[platform] [query]" — "youtube funny cats" / "reddit swift tips" / "amazon headphones"
        // Only match if the first word resolves to a site and there's a query after it
        let firstSpace = input.firstIndex(of: " ")
        if let spaceIdx = firstSpace {
            let firstWord = String(input[input.startIndex..<spaceIdx])
            let rest = String(input[input.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty && resolveURL(firstWord) != nil {
                return try? await openSearchURL(platform: firstWord, query: rest)
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

        // "google [query]" — explicit google search
        if input.hasPrefix("google ") {
            let query = String(input.dropFirst("google ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                return try? await SearchWebTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\"}")
            }
        }

        // "google images [query]" / "image search [query]"
        if input.hasPrefix("google images ") || input.hasPrefix("image search ") {
            let prefix = input.hasPrefix("google images ") ? "google images " : "image search "
            let query = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                let url = "https://www.google.com/search?tbm=isch&q=\(encoded)"
                return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
            }
        }

        // "maps [query]" / "directions to [place]" / "map of [place]"
        for p in ["directions to ", "map of ", "maps "] as [String] {
            if input.hasPrefix(p) {
                let query = String(input.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty {
                    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                    let url = "https://www.google.com/maps/search/\(encoded)"
                    return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
                }
            }
        }

        return nil
    }

    // MARK: - URL Resolution

    /// Resolves a spoken/typed target into a valid URL.
    /// Handles: full URLs, domains with dots, and common single-word site names.
    /// For unknown single words, tries {word}.com as a dynamic fallback.
    func resolveURL(_ target: String) -> String? {
        let clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(" ") else { return nil }

        // Already a URL
        if clean.hasPrefix("http://") || clean.hasPrefix("https://") {
            return clean
        }

        // Looks like a domain (contains a dot)
        if clean.contains(".") {
            return "https://\(clean)"
        }

        // Known shortcuts for sites where the URL is non-obvious
        if let url = Self.siteShortcuts[clean.lowercased()] {
            return url
        }

        // Dynamic fallback: try {name}.com for single words that look like site names
        // Only for lowercase alphabetic words (avoid matching "42", "and", etc.)
        let lower = clean.lowercased()
        if lower.count >= 3 && lower.allSatisfy({ $0.isLetter }) && !Self.nonSiteWords.contains(lower) {
            return "https://www.\(lower).com"
        }

        return nil
    }

    // Words that shouldn't be resolved as {word}.com — common English words that aren't websites
    private static let nonSiteWords: Set<String> = [
        // Prepositions & conjunctions
        "the", "and", "for", "but", "not", "with", "from", "that", "this", "what",
        "where", "when", "how", "why", "who", "which", "into", "onto", "upon",
        // Common verbs
        "open", "close", "find", "search", "play", "stop", "start", "move", "show",
        "hide", "set", "get", "run", "make", "take", "give", "tell", "send", "read",
        "write", "copy", "paste", "delete", "save", "quit", "exit", "launch", "click",
        "type", "press", "scroll", "drag", "watch", "look", "turn", "switch", "toggle",
        "create", "edit", "download", "install", "build", "remove", "update", "check",
        "change", "add", "help", "fix", "convert", "record", "design", "generate",
        "upload", "share", "connect", "trim", "merge", "resize", "export", "import",
        "analyze", "compare", "organize", "sort", "clean", "reset", "configure", "setup",
        // Common nouns/adjectives
        "file", "folder", "window", "tab", "page", "screen", "volume", "brightness",
        "music", "song", "timer", "alarm", "note", "reminder", "dark", "light", "mode",
        "all", "new", "current", "last", "next", "my", "the", "app", "apps",
    ]

    // Only sites where the URL is non-obvious (not just {name}.com)
    private static let siteShortcuts: [String: String] = [
        // URL differs from name
        "twitter": "https://x.com",
        "x": "https://x.com",
        "gmail": "https://mail.google.com",
        "hacker news": "https://news.ycombinator.com",
        "hackernews": "https://news.ycombinator.com",
        "hn": "https://news.ycombinator.com",
        "stack overflow": "https://stackoverflow.com",
        "stackoverflow": "https://stackoverflow.com",
        "whatsapp": "https://web.whatsapp.com",
        "telegram": "https://web.telegram.org",
        "chatgpt": "https://chat.openai.com",
        "claude": "https://claude.ai",
        "wikipedia": "https://en.wikipedia.org",
        "spotify": "https://open.spotify.com",
        "apple music": "https://music.apple.com",
        "disney plus": "https://www.disneyplus.com",
        "disney+": "https://www.disneyplus.com",
        "prime video": "https://www.amazon.com/gp/video/storefront",
        "messenger": "https://www.messenger.com",
        "best buy": "https://www.bestbuy.com",
        "bestbuy": "https://www.bestbuy.com",
        "uber eats": "https://www.ubereats.com",
        "rotten tomatoes": "https://www.rottentomatoes.com",
        "new york times": "https://www.nytimes.com",
        "nytimes": "https://www.nytimes.com",
        "nyt": "https://www.nytimes.com",
        "wsj": "https://www.wsj.com",
        "wall street journal": "https://www.wsj.com",
        "bbc": "https://www.bbc.com",
        "cnn": "https://www.cnn.com",
        "bluesky": "https://bsky.app",
        "wolfram": "https://www.wolframalpha.com",
        "wolfram alpha": "https://www.wolframalpha.com",
        // Google suite
        "maps": "https://maps.google.com",
        "google maps": "https://maps.google.com",
        "google drive": "https://drive.google.com",
        "drive": "https://drive.google.com",
        "docs": "https://docs.google.com",
        "google docs": "https://docs.google.com",
        "sheets": "https://sheets.google.com",
        "google sheets": "https://sheets.google.com",
        "slides": "https://slides.google.com",
        "google slides": "https://slides.google.com",
        "calendar": "https://calendar.google.com",
        "google calendar": "https://calendar.google.com",
        "google scholar": "https://scholar.google.com",
        "google images": "https://images.google.com",
        // Non-.com TLDs
        "notion": "https://www.notion.so",
        "discord": "https://discord.com/app",
        "slack": "https://app.slack.com",
        "twitch": "https://www.twitch.tv",
        "npm": "https://www.npmjs.com",
        "pypi": "https://pypi.org",
        "crates": "https://crates.io",
        "gitlab": "https://gitlab.com",
        "bitbucket": "https://bitbucket.org",
        "linear": "https://linear.app",
        "asana": "https://app.asana.com",
        "threads": "https://www.threads.net",
        "mastodon": "https://mastodon.social",
    ]

    // MARK: - Platform Search

    /// Handles "search [platform] for [query]" / "[platform] [query]" patterns.
    private func tryPlatformSearch(_ input: String) async -> String? {
        // "search [platform] for [query]"
        if input.hasPrefix("search ") && input.contains(" for ") {
            let afterSearch = String(input.dropFirst("search ".count))
            if let forRange = afterSearch.range(of: " for ") {
                let platform = String(afterSearch[afterSearch.startIndex..<forRange.lowerBound])
                let query = String(afterSearch[forRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !platform.isEmpty && !query.isEmpty && resolveURL(platform) != nil {
                    return try? await openSearchURL(platform: platform, query: query)
                }
            }
        }
        return nil
    }

    /// Opens the best search URL for a platform + query.
    /// Uses native search URLs for top sites, falls back to Google site: search for everything else.
    private func openSearchURL(platform: String, query: String) async throws -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        // Check if we have a native search URL for this platform
        if let url = Self.nativeSearchURL(platform: platform, query: query) {
            return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
        }

        // Fallback: Google site-scoped search — works for ANY website
        let domain = Self.resolveDomain(platform)
        let url = "https://www.google.com/search?q=\(encoded)+site:\(domain)"
        return try? await OpenInSafariTool().execute(arguments: "{\"url\": \"\(url)\"}")
    }

    /// Returns the domain for a platform name. "youtube" → "youtube.com", "youtube.com" → "youtube.com"
    private static func resolveDomain(_ platform: String) -> String {
        let lower = platform.lowercased()
        // Already has a TLD
        if lower.contains(".") { return lower }
        // Check shortcuts for non-obvious domains
        if let url = siteShortcuts[lower],
           let host = URL(string: url)?.host {
            return host
        }
        // Default: {name}.com
        return "\(lower).com"
    }

    /// Native search URL patterns for sites where we know the exact format.
    /// Only the top ~10 sites people actually search on. Everything else gets Google site: search.
    private static func nativeSearchURL(platform: String, query: String) -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let normalized = normalizePlatform(platform)
        switch normalized {
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
        case "stackoverflow", "stack overflow":
            return "https://stackoverflow.com/search?q=\(encoded)"
        case "spotify":
            return "https://open.spotify.com/search/\(encoded)"
        case "google maps", "maps":
            return "https://www.google.com/maps/search/\(encoded)"
        case "google images":
            return "https://www.google.com/search?tbm=isch&q=\(encoded)"
        case "google scholar":
            return "https://scholar.google.com/scholar?q=\(encoded)"
        default:
            return nil
        }
    }

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

    /// Build a search URL for a given platform. Accepts both "youtube" and "youtube.com" forms.
    /// Kept for backward compatibility — delegates to nativeSearchURL + Google fallback.
    func searchURLForPlatform(_ platform: String, query: String) -> String? {
        // Try native first
        if let url = Self.nativeSearchURL(platform: platform, query: query) {
            return url
        }
        // Google site: fallback
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let domain = Self.resolveDomain(platform)
        return "https://www.google.com/search?q=\(encoded)+site:\(domain)"
    }

    // MARK: - Compound "open X and search for Y"

    /// Handles "open youtube and search for how claw works", "go to reddit and look up swift concurrency", etc.
    /// Also handles domain forms: "go to youtube.com and search for funny cat videos".
    private func tryCompoundOpenAndSearch(_ input: String) async -> String? {
        let openPrefixes = ["open ", "go to ", "navigate to "]
        let searchSeparators = [" and search for ", " and search ", " and look up ", " and find "]

        for prefix in openPrefixes {
            guard input.hasPrefix(prefix) else { continue }
            let afterPrefix = String(input.dropFirst(prefix.count))

            for sep in searchSeparators {
                guard let sepRange = afterPrefix.range(of: sep) else { continue }
                let rawPlatform = String(afterPrefix[afterPrefix.startIndex..<sepRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let query = String(afterPrefix[sepRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)

                guard !rawPlatform.isEmpty, !query.isEmpty else { continue }

                // Platform must be resolvable (known shortcut, has a dot, or resolves to .com)
                guard resolveURL(rawPlatform) != nil else { continue }

                return try? await openSearchURL(platform: rawPlatform, query: query)
            }
        }

        return nil
    }

    /// Strips domain suffixes and "www." to get a clean platform name for lookup.
    /// "youtube.com" → "youtube", "www.reddit.com" → "reddit", "en.wikipedia.org" → "wikipedia"
    private static func normalizePlatform(_ raw: String) -> String {
        var name = raw.lowercased()
        for prefix in ["www.", "en.", "web.", "app.", "m."] {
            if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        }
        for suffix in [".com", ".org", ".net", ".io", ".tv", ".co", ".ai", ".so", ".gg", ".app"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        return name
    }
}
