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
        NSWorkspace.shared.open(url)
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
        let url = URL(string: "https://www.google.com/search?q=\(encoded)")!
        NSWorkspace.shared.open(url)
        return "Searching for '\(query)'."
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
        try AppleScriptRunner.runThrowing("tell application \"Safari\" to open location \"\(url)\"")
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
        let script = """
        tell application "Safari"
            activate
            tell front window
                set current tab to (make new tab with properties {URL:"\(url)"})
            end tell
        end tell
        """
        try AppleScriptRunner.runThrowing(script)
        return "Opened new Safari tab."
    }
}
