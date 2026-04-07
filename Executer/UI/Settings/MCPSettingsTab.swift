import SwiftUI

// MARK: - Main Tab

struct MCPSettingsTab: View {
    @State private var serverStatuses: [String: MCPServerManager.ServerStatus] = [:]
    @State private var configuredServers: [MCPServerManager.ServerConfig] = []
    @State private var selectedEntry: MCPCatalogEntry?
    @State private var showCustomSheet = false
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Integrations")
                            .font(.title2.bold())
                        Text("Connect apps to extend Executer's capabilities via MCP")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: refreshStatuses) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh connection status")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // App catalog grid by category
                ForEach(MCPServerCatalog.byCategory, id: \.0) { category, entries in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.rawValue)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 160), spacing: 12)
                        ], spacing: 12) {
                            ForEach(entries) { entry in
                                MCPAppCard(
                                    entry: entry,
                                    status: statusFor(entry.id),
                                    onTap: { selectedEntry = entry }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Connected custom servers (not in catalog)
                let customServers = configuredServers.filter { config in
                    MCPServerCatalog.entry(for: config.name) == nil
                }
                if !customServers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Servers")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        ForEach(customServers, id: \.name) { config in
                            MCPCustomServerRow(
                                config: config,
                                status: statusFor(config.name),
                                onDisconnect: { disconnectServer(config.name) }
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                }

                // Add custom server button
                Button(action: { showCustomSheet = true }) {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Add Custom MCP Server")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .onAppear { loadState() }
        .sheet(item: $selectedEntry) { entry in
            MCPConnectSheet(
                entry: entry,
                isConnected: statusFor(entry.id).isConnected,
                existingEnv: existingEnv(for: entry.id),
                onConnect: { creds in connectCatalogServer(entry, credentials: creds) },
                onDisconnect: { disconnectServer(entry.id) }
            )
        }
        .sheet(isPresented: $showCustomSheet) {
            MCPCustomServerSheet(onSave: { config in connectCustomServer(config) })
        }
    }

    // MARK: - Helpers

    private func statusFor(_ name: String) -> MCPServerManager.ServerStatus {
        serverStatuses[name] ?? .disconnected
    }

    private func existingEnv(for name: String) -> [String: String] {
        configuredServers.first { $0.name == name }?.env ?? [:]
    }

    private func loadState() {
        configuredServers = MCPServerManager.shared.loadConfig()
        Task {
            let statuses = await MCPServerManager.shared.allStatuses()
            await MainActor.run { serverStatuses = statuses }
        }
    }

    private func refreshStatuses() {
        isRefreshing = true
        Task {
            let statuses = await MCPServerManager.shared.allStatuses()
            await MainActor.run {
                serverStatuses = statuses
                isRefreshing = false
            }
        }
    }

    private func connectCatalogServer(_ entry: MCPCatalogEntry, credentials: [String: String]) {
        serverStatuses[entry.id] = .connecting
        Task {
            let config = MCPServerManager.shared.configFromCatalog(entry, credentialValues: credentials)
            let count = await MCPServerManager.shared.connectSingle(config)
            let newStatus = await MCPServerManager.shared.status(for: entry.id)
            await MainActor.run {
                serverStatuses[entry.id] = newStatus
                configuredServers = MCPServerManager.shared.loadConfig()
            }
        }
    }

    private func connectCustomServer(_ config: MCPServerManager.ServerConfig) {
        serverStatuses[config.name] = .connecting
        Task {
            await MCPServerManager.shared.connectSingle(config)
            let newStatus = await MCPServerManager.shared.status(for: config.name)
            await MainActor.run {
                serverStatuses[config.name] = newStatus
                configuredServers = MCPServerManager.shared.loadConfig()
            }
        }
    }

    private func disconnectServer(_ name: String) {
        Task {
            await MCPServerManager.shared.removeSingle(named: name)
            await MainActor.run {
                serverStatuses[name] = .disconnected
                configuredServers = MCPServerManager.shared.loadConfig()
                selectedEntry = nil
            }
        }
    }
}

// MARK: - App Card

struct MCPAppCard: View {
    let entry: MCPCatalogEntry
    let status: MCPServerManager.ServerStatus
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: entry.icon)
                        .font(.system(size: 22))
                        .frame(width: 40, height: 40)
                        .background(iconBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    statusDot
                        .offset(x: 3, y: 3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Text(statusLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(status.isConnected ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconBackground: Color {
        switch entry.category {
        case .productivity: return .blue.opacity(0.15)
        case .development: return .purple.opacity(0.15)
        case .communication: return .orange.opacity(0.15)
        case .media: return .green.opacity(0.15)
        case .design: return .pink.opacity(0.15)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .connected:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .connecting:
            Circle().fill(.yellow).frame(width: 8, height: 8)
        case .error:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .disconnected:
            EmptyView()
        }
    }

    private var statusLabel: String {
        switch status {
        case .connected(let count): return "\(count) tools available"
        case .connecting: return "Connecting..."
        case .error(let msg): return "Error: \(msg.prefix(30))"
        case .disconnected: return "Not connected"
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .disconnected: return .secondary
        }
    }
}

// MARK: - Connect Sheet

struct MCPConnectSheet: View {
    let entry: MCPCatalogEntry
    let isConnected: Bool
    let existingEnv: [String: String]
    let onConnect: ([String: String]) -> Void
    let onDisconnect: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var credentialValues: [String: String] = [:]
    @State private var isConnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: entry.icon)
                    .font(.system(size: 28))
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.title3.bold())
                    Text(entry.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Setup instructions
            Text(entry.setupInstructions)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = entry.setupURL {
                Link(destination: URL(string: url)!) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Get credentials")
                    }
                    .font(.system(size: 12))
                }
            }

            // Credential fields
            if !entry.credentials.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(entry.credentials) { cred in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cred.label)
                                .font(.system(size: 12, weight: .medium))

                            if cred.isSecret {
                                SecureField(cred.placeholder, text: binding(for: cred.id))
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField(cred.placeholder, text: binding(for: cred.id))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isConnected {
                    Button("Disconnect", role: .destructive) {
                        onDisconnect()
                        dismiss()
                    }

                    Button("Reconnect") {
                        isConnecting = true
                        onConnect(credentialValues)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Connect") {
                        isConnecting = true
                        onConnect(credentialValues)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allCredentialsFilled && !entry.credentials.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: max(350, CGFloat(entry.credentials.count * 60 + 280)))
        .onAppear {
            // Pre-fill with existing values
            for cred in entry.credentials {
                credentialValues[cred.id] = existingEnv[cred.id] ?? ""
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { credentialValues[key] ?? "" },
            set: { credentialValues[key] = $0 }
        )
    }

    private var allCredentialsFilled: Bool {
        entry.credentials.allSatisfy { cred in
            let val = credentialValues[cred.id] ?? ""
            return !val.isEmpty
        }
    }
}

// MARK: - Custom Server Sheet

struct MCPCustomServerSheet: View {
    let onSave: (MCPServerManager.ServerConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var transport: MCPServerManager.TransportType = .stdio
    @State private var command = "npx"
    @State private var args = ""
    @State private var envText = ""  // KEY=VALUE per line
    @State private var url = ""
    @State private var headersText = ""  // KEY: VALUE per line

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Custom MCP Server")
                .font(.title3.bold())

            Divider()

            TextField("Server Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Transport", selection: $transport) {
                Text("stdio").tag(MCPServerManager.TransportType.stdio)
                Text("SSE").tag(MCPServerManager.TransportType.sse)
                Text("Streamable HTTP").tag(MCPServerManager.TransportType.streamableHTTP)
            }
            .pickerStyle(.segmented)

            if transport == .stdio {
                TextField("Command (e.g. npx)", text: $command)
                    .textFieldStyle(.roundedBorder)
                TextField("Arguments (space-separated)", text: $args)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment Variables")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $envText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 60)
                        .border(Color.gray.opacity(0.3))
                    Text("One per line: KEY=VALUE")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("URL", text: $url)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Headers")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $headersText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 60)
                        .border(Color.gray.opacity(0.3))
                    Text("One per line: Key: Value")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") {
                    let config = buildConfig()
                    onSave(config)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 400)
    }

    private func buildConfig() -> MCPServerManager.ServerConfig {
        let env = parseKeyValue(envText, separator: "=")
        let headers = parseKeyValue(headersText, separator: ":")
        let argsList = args.split(separator: " ").map(String.init)

        return MCPServerManager.ServerConfig(
            name: name.lowercased().replacingOccurrences(of: " ", with: "-"),
            transport: transport,
            command: transport == .stdio ? command : nil,
            args: transport == .stdio && !argsList.isEmpty ? argsList : nil,
            env: transport == .stdio && !env.isEmpty ? env : nil,
            url: transport != .stdio ? url : nil,
            headers: transport != .stdio && !headers.isEmpty ? headers : nil
        )
    }

    private func parseKeyValue(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let idx = line.firstIndex(of: separator) else { continue }
            let key = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

// MARK: - Custom Server Row

struct MCPCustomServerRow: View {
    let config: MCPServerManager.ServerConfig
    let status: MCPServerManager.ServerStatus
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.system(size: 13, weight: .medium))
                Text(transportLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusView

            Button(action: onDisconnect) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Disconnect and remove")
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var transportLabel: String {
        let t = config.effectiveTransport
        switch t {
        case .stdio: return config.command ?? "stdio"
        case .sse: return config.url ?? "SSE"
        case .streamableHTTP: return config.url ?? "HTTP"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .connected(let count):
            Text("\(count) tools")
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        case .connecting:
            ProgressView()
                .controlSize(.mini)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12))
        case .disconnected:
            Text("Off")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Identifiable conformance

extension MCPCatalogEntry: Equatable {
    static func == (lhs: MCPCatalogEntry, rhs: MCPCatalogEntry) -> Bool {
        lhs.id == rhs.id
    }
}

extension MCPCatalogEntry: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
