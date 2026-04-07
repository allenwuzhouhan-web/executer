import Foundation

/// Manages multiple MCP server connections and their discovered tools.
/// Actor-isolated to prevent data races on clients/discoveredTools.
actor MCPServerManager {
    static let shared = MCPServerManager()

    private var clients: [String: any MCPTransport] = [:]
    private var discoveredTools: [MCPToolWrapper] = []
    private let configURL: URL

    /// Per-server connection status, published for UI observation.
    private(set) var serverStatuses: [String: ServerStatus] = [:]

    // MARK: - Status Model

    enum ServerStatus: Equatable {
        case disconnected
        case connecting
        case connected(toolCount: Int)
        case error(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // MARK: - Config Model

    enum TransportType: String, Codable {
        case stdio
        case sse
        case streamableHTTP = "streamable-http"
    }

    struct ServerConfig: Codable {
        let name: String
        let transport: TransportType?  // nil = stdio (backward compat)

        // stdio fields
        let command: String?
        let args: [String]?
        let env: [String: String]?

        // HTTP fields (SSE / streamable-http)
        let url: String?
        let headers: [String: String]?

        var effectiveTransport: TransportType {
            transport ?? .stdio
        }
    }

    struct Config: Codable {
        let servers: [ServerConfig]
    }

    private init() {
        let appSupport = URL.applicationSupportDirectory
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
        serverStatuses.removeAll()
    }

    /// Get list of connected server names.
    var connectedServers: [String] {
        Array(clients.keys)
    }

    /// Get all discovered tool names.
    var toolNames: [String] {
        discoveredTools.map { $0.name }
    }

    // MARK: - Single Server Connect / Disconnect (Runtime)

    /// Connect a single server by config, register its tools, and return discovered tool count.
    /// Used by the settings UI for live connect without app restart.
    @discardableResult
    func connectSingle(_ config: ServerConfig) async -> Int {
        // Disconnect first if already connected
        await disconnectSingle(named: config.name)

        // Save to persistent config
        addServer(config)

        // Connect
        await connectServer(config)

        // Register new tools into ToolRegistry
        let newTools = discoveredTools.filter { $0.name.hasPrefix("mcp_\(config.name)_") }
        if !newTools.isEmpty {
            await MainActor.run {
                ToolRegistry.shared.registerMCPTools(newTools)
            }
        }
        return newTools.count
    }

    /// Disconnect a single server and unregister its tools.
    func disconnectSingle(named name: String) async {
        if let client = clients[name] {
            await client.disconnect()
            clients.removeValue(forKey: name)
            discoveredTools.removeAll { $0.name.hasPrefix("mcp_\(name)_") }
            await MainActor.run {
                ToolRegistry.shared.unregisterMCPTools(forServer: name)
            }
            print("[MCP] Disconnected \(name)")
        }
        serverStatuses[name] = .disconnected
    }

    /// Disconnect and remove a server from config entirely.
    func removeSingle(named name: String) async {
        await disconnectSingle(named: name)
        removeServer(named: name)
        serverStatuses.removeValue(forKey: name)
    }

    /// Reconnect all servers (hot-reload config).
    func reconnectAll() async {
        await shutdownAll()
        await connectAll()
        let tools = getDiscoveredTools()
        if !tools.isEmpty {
            await MainActor.run {
                ToolRegistry.shared.registerMCPTools(tools)
            }
        }
    }

    /// Check if a server name is currently connected.
    func isConnected(_ name: String) -> Bool {
        serverStatuses[name]?.isConnected ?? false
    }

    /// Get the status for a server.
    func status(for name: String) -> ServerStatus {
        serverStatuses[name] ?? .disconnected
    }

    /// Get all server statuses (for UI snapshot).
    func allStatuses() -> [String: ServerStatus] {
        serverStatuses
    }

    /// Get tool count for a connected server.
    func toolCount(for serverName: String) -> Int {
        discoveredTools.filter { $0.name.hasPrefix("mcp_\(serverName)_") }.count
    }

    // MARK: - Server Management

    private func connectServer(_ config: ServerConfig) async {
        serverStatuses[config.name] = .connecting
        let client: any MCPTransport

        switch config.effectiveTransport {
        case .stdio:
            guard let command = config.command, let args = config.args else {
                print("[MCP] stdio server \(config.name) missing command/args")
                serverStatuses[config.name] = .error("Missing command/args")
                return
            }
            let stdioClient = MCPClient(name: config.name)
            do {
                try await stdioClient.connect(command: command, args: args, env: config.env ?? [:])
            } catch {
                print("[MCP] Failed to connect stdio \(config.name): \(error.localizedDescription)")
                await stdioClient.disconnect()
                serverStatuses[config.name] = .error(error.localizedDescription)
                return
            }
            client = stdioClient

        case .sse:
            guard let urlStr = config.url, let url = URL(string: urlStr) else {
                print("[MCP] SSE server \(config.name) missing/invalid url")
                serverStatuses[config.name] = .error("Missing/invalid URL")
                return
            }
            let httpClient = MCPHTTPClient(
                name: config.name, url: url,
                mode: .sse, headers: config.headers ?? [:]
            )
            do {
                try await httpClient.connect()
            } catch {
                print("[MCP] Failed to connect SSE \(config.name): \(error.localizedDescription)")
                await httpClient.disconnect()
                serverStatuses[config.name] = .error(error.localizedDescription)
                return
            }
            client = httpClient

        case .streamableHTTP:
            guard let urlStr = config.url, let url = URL(string: urlStr) else {
                print("[MCP] streamable-http server \(config.name) missing/invalid url")
                serverStatuses[config.name] = .error("Missing/invalid URL")
                return
            }
            let httpClient = MCPHTTPClient(
                name: config.name, url: url,
                mode: .streamableHTTP, headers: config.headers ?? [:]
            )
            do {
                try await httpClient.connect()
            } catch {
                print("[MCP] Failed to connect streamable-http \(config.name): \(error.localizedDescription)")
                await httpClient.disconnect()
                serverStatuses[config.name] = .error(error.localizedDescription)
                return
            }
            client = httpClient
        }

        // Discover tools (same for all transports)
        do {
            let tools = try await client.listTools()
            let wrappers = tools.map { MCPToolWrapper(serverName: config.name, tool: $0, client: client) }
            clients[config.name] = client
            discoveredTools.append(contentsOf: wrappers)
            serverStatuses[config.name] = .connected(toolCount: tools.count)

            print("[MCP] \(config.name) [\(config.effectiveTransport)]: discovered \(tools.count) tools")
            for t in tools {
                print("[MCP]   - \(t.name): \(t.description.prefix(60))")
            }
        } catch {
            print("[MCP] Failed to discover tools for \(config.name): \(error.localizedDescription)")
            await client.disconnect()
            serverStatuses[config.name] = .error("Tool discovery failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Config (nonisolated since it only reads/writes files)

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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
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

    // MARK: - Catalog Helpers

    /// Build a ServerConfig from a catalog entry and user-provided credential values.
    nonisolated func configFromCatalog(
        _ entry: MCPCatalogEntry,
        credentialValues: [String: String]
    ) -> ServerConfig {
        var env: [String: String] = [:]
        var headers: [String: String] = [:]

        for cred in entry.credentials {
            guard let value = credentialValues[cred.id], !value.isEmpty else { continue }
            if cred.isHeader {
                headers[cred.id] = value
            } else {
                env[cred.id] = value
            }
        }

        // Special handling: filesystem server appends allowed dirs to args
        var args = entry.args ?? []
        if entry.id == "filesystem", let dirs = credentialValues["ALLOWED_DIRS"] {
            let paths = dirs.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            args.append(contentsOf: paths)
        }

        return ServerConfig(
            name: entry.id,
            transport: entry.transport,
            command: entry.command,
            args: args.isEmpty ? nil : args,
            env: env.isEmpty ? nil : env,
            url: entry.url,
            headers: headers.isEmpty ? nil : headers
        )
    }
}
