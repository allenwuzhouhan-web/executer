import Foundation

/// Manages multiple MCP server connections and their discovered tools.
/// Actor-isolated to prevent data races on clients/discoveredTools.
actor MCPServerManager {
    static let shared = MCPServerManager()

    private var clients: [String: MCPClient] = [:]
    private var discoveredTools: [MCPToolWrapper] = []
    private let configURL: URL

    struct ServerConfig: Codable {
        let name: String
        let command: String
        let args: [String]
        let env: [String: String]?
    }

    struct Config: Codable {
        let servers: [ServerConfig]
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        configURL = appSupport.appendingPathComponent("Executer/mcp_servers.json")
    }

    // MARK: - Lifecycle

    /// Connect to all configured MCP servers and discover their tools.
    func connectAll() async {
        // Disconnect existing servers first to prevent duplicates
        await shutdownAll()

        let configs = loadConfig()
        if configs.isEmpty {
            print("[MCP] No servers configured at \(configURL.path)")
            return
        }

        for config in configs {
            await connectServer(config)
        }

        print("[MCP] Connected \(clients.count) server(s), discovered \(discoveredTools.count) tool(s)")
    }

    /// Get all discovered MCP tools (for registration into ToolRegistry).
    func getDiscoveredTools() -> [MCPToolWrapper] {
        return discoveredTools
    }

    /// Disconnect all servers.
    func shutdownAll() async {
        for (name, client) in clients {
            await client.disconnect()
            print("[MCP] Disconnected \(name)")
        }
        clients.removeAll()
        discoveredTools.removeAll()
    }

    /// Get list of connected server names.
    var connectedServers: [String] {
        Array(clients.keys)
    }

    /// Get all discovered tool names.
    var toolNames: [String] {
        discoveredTools.map { $0.name }
    }

    // MARK: - Server Management

    private func connectServer(_ config: ServerConfig) async {
        let client = MCPClient(name: config.name)
        do {
            try await client.connect(
                command: config.command,
                args: config.args,
                env: config.env ?? [:]
            )

            let tools = try await client.listTools()
            let wrappers = tools.map { MCPToolWrapper(serverName: config.name, tool: $0, client: client) }

            clients[config.name] = client
            discoveredTools.append(contentsOf: wrappers)

            print("[MCP] \(config.name): discovered \(tools.count) tools")
            for t in tools {
                print("[MCP]   - \(t.name): \(t.description.prefix(60))")
            }
        } catch {
            print("[MCP] Failed to connect \(config.name): \(error.localizedDescription)")
            await client.disconnect()
        }
    }

    // MARK: - Config (nonisolated since it only reads files)

    nonisolated func loadConfig() -> [ServerConfig] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(Config.self, from: data).servers
        } catch {
            print("[MCP] Config error: \(error)")
            return []
        }
    }

    nonisolated func saveConfig(_ servers: [ServerConfig]) {
        let config = Config(servers: servers)
        if let data = try? JSONEncoder().encode(config) {
            try? FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: configURL)
        }
    }

    nonisolated func addServer(_ server: ServerConfig) {
        var configs = loadConfig()
        configs.removeAll { $0.name == server.name }
        configs.append(server)
        saveConfig(configs)
    }

    nonisolated func removeServer(named name: String) {
        var configs = loadConfig()
        configs.removeAll { $0.name == name }
        saveConfig(configs)
    }
}
