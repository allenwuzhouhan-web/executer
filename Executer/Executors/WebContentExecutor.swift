import Foundation

// MARK: - Read Safari Page Text

struct ReadSafariPageTool: ToolDefinition {
    let name = "read_safari_page"
    let description = "Read the text content of the current Safari page. Returns the visible text (no HTML tags)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "max_length": JSONSchema.integer(description: "Maximum characters to return (default 5000)", minimum: 100, maximum: 20000),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let maxLength = optionalInt("max_length", from: args) ?? 5000

        let script = """
        tell application "Safari"
            if (count of windows) = 0 then return "No Safari windows open."
            if (count of tabs of front window) = 0 then return "No tabs open."
            set pageText to do JavaScript "document.body.innerText" in current tab of front window
            return pageText
        end tell
        """
        let result = try AppleScriptRunner.runThrowing(script)
        if result.isEmpty {
            return "Page has no text content."
        }
        let truncated = result.count > maxLength ? String(result.prefix(maxLength)) + "\n... (truncated)" : result
        return truncated
    }
}

// MARK: - Read Safari HTML

struct ReadSafariHTMLTool: ToolDefinition {
    let name = "read_safari_html"
    let description = "Read HTML content from the current Safari page. Optionally target a specific CSS selector."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "selector": JSONSchema.string(description: "CSS selector to target (e.g. 'article', '.main-content'). Omit for full page."),
            "max_length": JSONSchema.integer(description: "Maximum characters to return (default 10000)", minimum: 100, maximum: 50000),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let selector = optionalString("selector", from: args)
        let maxLength = optionalInt("max_length", from: args) ?? 10000

        let js: String
        if let selector = selector {
            let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
            js = "var el = document.querySelector('\(escaped)'); el ? el.innerHTML : 'Selector not found: \(escaped)'"
        } else {
            js = "document.documentElement.outerHTML"
        }

        let script = """
        tell application "Safari"
            if (count of windows) = 0 then return "No Safari windows open."
            set pageHTML to do JavaScript "\(AppleScriptRunner.escape(js))" in current tab of front window
            return pageHTML
        end tell
        """
        let result = try AppleScriptRunner.runThrowing(script)
        if result.isEmpty {
            return "No HTML content found."
        }
        let truncated = result.count > maxLength ? String(result.prefix(maxLength)) + "\n... (truncated)" : result
        return truncated
    }
}

// MARK: - Fetch URL Content

struct FetchURLContentTool: ToolDefinition {
    let name = "fetch_url_content"
    let description = "Fetch a URL and return its text content (HTML tags stripped). Useful for reading web pages without a browser."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "The URL to fetch"),
            "max_length": JSONSchema.integer(description: "Maximum characters to return (default 8000)", minimum: 100, maximum: 30000),
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let urlString = try requiredString("url", from: args)
        let maxLength = optionalInt("max_length", from: args) ?? 8000

        guard let url = URL(string: urlString) else {
            return "Invalid URL: \(urlString)"
        }

        // Block dangerous schemes and local addresses
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            return "Only http/https URLs are allowed."
        }

        let host = url.host?.lowercased() ?? ""
        if host == "localhost" || host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.") {
            return "Local/private URLs are not allowed."
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Executer/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await PinnedURLSession.shared.session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return "HTTP error: \(status)"
        }

        // Enforce 2MB download limit
        guard data.count <= 2_000_000 else {
            return "Response too large (\(data.count / 1024)KB). Max 2MB."
        }

        guard var text = String(data: data, encoding: .utf8) else {
            return "Could not decode response as text."
        }

        // Strip HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Normalize whitespace
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            return "Page returned no text content."
        }

        let truncated = text.count > maxLength ? String(text.prefix(maxLength)) + "\n... (truncated)" : text
        return truncated
    }
}

// MARK: - Read Chrome Page Text

struct ReadChromePageTool: ToolDefinition {
    let name = "read_chrome_page"
    let description = "Read the text content of the current Google Chrome page."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "max_length": JSONSchema.integer(description: "Maximum characters to return (default 5000)", minimum: 100, maximum: 20000),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let maxLength = optionalInt("max_length", from: args) ?? 5000

        let script = """
        tell application "Google Chrome"
            if (count of windows) = 0 then return "No Chrome windows open."
            set pageText to execute active tab of front window javascript "document.body.innerText"
            return pageText
        end tell
        """
        let result = try AppleScriptRunner.runThrowing(script)
        if result.isEmpty {
            return "Page has no text content."
        }
        let truncated = result.count > maxLength ? String(result.prefix(maxLength)) + "\n... (truncated)" : result
        return truncated
    }
}
