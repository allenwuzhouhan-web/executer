import Foundation

/// Unified web page reader — auto-dispatches to the best reading method.
struct ReadWebPageTool: ToolDefinition {
    let name = "read_web_page"
    let description = """
        Smart web page reader — automatically picks the best method to read a web page. \
        Provide a URL to fetch it directly. Provide source "safari" or "chrome" (no URL) to read the currently open tab. \
        This is the PREFERRED tool for reading web content. It handles URL fetching, Safari tabs, and Chrome tabs automatically.
        """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "URL to fetch. Omit to read the current browser tab."),
            "source": JSONSchema.enumString(description: "Which source to read: 'auto' (default), 'safari', 'chrome', 'fetch'", values: ["auto", "safari", "chrome", "fetch"]),
            "max_length": JSONSchema.integer(description: "Maximum characters to return (default 8000)", minimum: 100, maximum: 30000),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let url = optionalString("url", from: args)
        let source = optionalString("source", from: args) ?? "auto"
        let maxLength = optionalInt("max_length", from: args) ?? 8000

        switch source {
        case "safari":
            return try await ReadSafariPageTool().execute(arguments: encodeArgs(["max_length": maxLength]))
        case "chrome":
            return try await ReadChromePageTool().execute(arguments: encodeArgs(["max_length": maxLength]))
        case "fetch":
            guard let url = url else { return "Error: URL required for fetch mode." }
            return try await FetchURLContentTool().execute(arguments: encodeArgs(["url": url, "max_length": maxLength]))
        default: // "auto"
            if let url = url {
                return try await FetchURLContentTool().execute(arguments: encodeArgs(["url": url, "max_length": maxLength]))
            }
            // No URL — try Safari first, fall back to Chrome
            if let safariResult = try? await ReadSafariPageTool().execute(arguments: encodeArgs(["max_length": maxLength])),
               !safariResult.contains("No Safari windows") {
                return safariResult
            }
            return try await ReadChromePageTool().execute(arguments: encodeArgs(["max_length": maxLength]))
        }
    }

    private func encodeArgs(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
