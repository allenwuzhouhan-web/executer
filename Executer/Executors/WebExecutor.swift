import Cocoa

struct OpenURLTool: ToolDefinition {
    let name = "open_url"
    let description = "Open a URL in the default browser"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "The URL to open")
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let urlString = try requiredString("url", from: args)
        guard let url = URL(string: urlString) else {
            return "Invalid URL: \(urlString)"
        }
        // Prefer Safari for http/https URLs (macOS-native optimization)
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            let escaped = AppleScriptRunner.escape(urlString)
            try? AppleScriptRunner.runThrowing("tell application \"Safari\" to open location \"\(escaped)\"")
        } else {
            NSWorkspace.shared.open(url)
        }
        return "Opened \(urlString)."
    }
}

struct SearchWebTool: ToolDefinition {
    let name = "search_web"
    let description = "Search the web using Google in the default browser"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "The search query")
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let safariURL = "https://www.google.com/search?q=\(encoded)"
        let escaped = AppleScriptRunner.escape(safariURL)
        try? AppleScriptRunner.runThrowing("tell application \"Safari\" to open location \"\(escaped)\"")

        // Also try instant search to return actual data to the LLM
        let instantResult = try? await InstantSearchTool().execute(arguments: arguments)
        if let result = instantResult, !result.contains("No instant answer") {
            return "Opened Google search in Safari.\n\nInstant answer:\n\(result)"
        }
        return "Opened Google search in Safari for '\(query)'. Use read_safari_page to get the results."
    }
}

struct OpenInSafariTool: ToolDefinition {
    let name = "open_url_in_safari"
    let description = "Open a URL specifically in Safari"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "The URL to open in Safari")
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let url = try requiredString("url", from: args)
        guard URL(string: url) != nil else {
            return "Invalid URL: \(url)"
        }
        let escaped = AppleScriptRunner.escape(url)
        try AppleScriptRunner.runThrowing("tell application \"Safari\" to open location \"\(escaped)\"")
        try AppleScriptRunner.runThrowing("tell application \"Safari\" to activate")
        return "Opened in Safari."
    }
}

struct GetSafariURLTool: ToolDefinition {
    let name = "get_safari_url"
    let description = "Get the URL of the current Safari tab"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let result = try AppleScriptRunner.runThrowing(
            "tell application \"Safari\" to get URL of current tab of front window"
        )
        return "Current Safari URL: \(result)"
    }
}

struct GetSafariTitleTool: ToolDefinition {
    let name = "get_safari_title"
    let description = "Get the title of the current Safari tab"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let result = try AppleScriptRunner.runThrowing(
            "tell application \"Safari\" to get name of current tab of front window"
        )
        return "Current Safari tab: \(result)"
    }
}

struct GetChromeURLTool: ToolDefinition {
    let name = "get_chrome_url"
    let description = "Get the URL of the current Google Chrome tab"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let result = try AppleScriptRunner.runThrowing(
            "tell application \"Google Chrome\" to get URL of active tab of front window"
        )
        return "Current Chrome URL: \(result)"
    }
}

struct NewSafariTabTool: ToolDefinition {
    let name = "new_safari_tab"
    let description = "Open a URL in a new Safari tab"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "The URL to open in a new tab")
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let url = try requiredString("url", from: args)
        guard URL(string: url) != nil else {
            return "Invalid URL: \(url)"
        }
        let escaped = AppleScriptRunner.escape(url)
        let script = """
        tell application "Safari"
            activate
            tell front window
                set current tab to (make new tab with properties {URL:"\(escaped)"})
            end tell
        end tell
        """
        try AppleScriptRunner.runThrowing(script)
        return "Opened new Safari tab."
    }
}
