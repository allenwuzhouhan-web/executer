import Foundation

/// Wraps an MCP-discovered tool as a ToolDefinition for the Executer tool registry.
struct MCPToolWrapper: ToolDefinition {
    let name: String
    let description: String
    let parameters: [String: Any]

    private let originalName: String
    private let client: MCPClient

    init(serverName: String, tool: MCPClient.MCPTool, client: MCPClient) {
        self.originalName = tool.name
        self.name = "mcp_\(serverName)_\(tool.name)"
        self.description = "\(tool.description) [MCP: \(serverName)]"
        self.parameters = tool.inputSchema
        self.client = client
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        return try await client.callTool(name: originalName, arguments: args)
    }
}
