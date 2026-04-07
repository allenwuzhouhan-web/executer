import Foundation

/// Wraps an MCP-discovered tool as a ToolDefinition for the Executer tool registry.
struct MCPToolWrapper: ToolDefinition {
    let name: String
    let description: String
    let parameters: [String: Any]

    private let originalName: String
    private let client: any MCPTransport

    init(serverName: String, tool: MCPToolInfo, client: any MCPTransport) {
        self.originalName = tool.name
        self.name = "mcp_\(serverName)_\(tool.name)"
        self.description = "\(tool.description) [MCP: \(serverName)]"
        self.parameters = tool.inputSchema
        self.client = client
    }

    func execute(arguments: String) async throws -> String {
        // Liveness check: reconnect if server process died
        try await client.ensureConnected()
        let args = try parseArguments(arguments)
        return try await client.callTool(name: originalName, arguments: args)
    }
}
