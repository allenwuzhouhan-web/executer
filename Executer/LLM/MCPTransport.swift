import Foundation

/// Shared MCP tool descriptor used by all transports.
struct MCPToolInfo {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

/// Abstraction over MCP transport (stdio, SSE, streamable-http).
/// Both MCPClient and MCPHTTPClient conform to this.
protocol MCPTransport: AnyObject, Sendable {
    var serverName: String { get }
    var isAlive: Bool { get async }

    func connect() async throws
    func disconnect() async
    func ensureConnected() async throws
    func listTools() async throws -> [MCPToolInfo]
    func callTool(name: String, arguments: [String: Any]) async throws -> String
}

// MARK: - Shared Errors

enum MCPError: LocalizedError {
    case disconnected
    case encodingError
    case serverError(code: Int, message: String)
    case timeout
    case connectionFailed(String)
    case invalidResponse
    case sessionExpired
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "MCP server disconnected"
        case .encodingError: return "Failed to encode MCP message"
        case .serverError(_, let msg): return "MCP server error: \(msg)"
        case .timeout: return "MCP request timed out"
        case .connectionFailed(let msg): return "MCP connection failed: \(msg)"
        case .invalidResponse: return "Invalid MCP response"
        case .sessionExpired: return "MCP session expired"
        case .httpError(let code, let body): return "MCP HTTP error \(code): \(body)"
        }
    }
}
