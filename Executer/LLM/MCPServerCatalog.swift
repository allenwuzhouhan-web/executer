import Foundation

// MARK: - Catalog Entry Model

/// A pre-configured MCP server definition from the built-in catalog.
struct MCPCatalogEntry: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String          // SF Symbol name
    let category: MCPAppCategory
    let transport: MCPServerManager.TransportType

    // stdio
    let command: String?
    let args: [String]?

    // HTTP
    let url: String?

    /// Environment variables / headers the user must provide.
    let credentials: [MCPCredentialField]

    /// URL where the user can create/get their API key or token.
    let setupURL: String?

    /// Short setup instructions shown in the config sheet.
    let setupInstructions: String

    /// Whether this server requires a Python runtime (uv) instead of Node.
    let requiresPython: Bool
}

/// A credential field the user must fill in to connect a server.
struct MCPCredentialField: Identifiable {
    let id: String        // env var name or header key
    let label: String     // human-readable label
    let placeholder: String
    let isSecret: Bool    // mask input
    let isHeader: Bool    // true = HTTP header, false = env var
}

/// Categories for grouping servers in the UI.
enum MCPAppCategory: String, CaseIterable {
    case productivity = "Productivity"
    case development = "Development"
    case communication = "Communication"
    case media = "Media"
    case design = "Design"
}

// MARK: - Built-in Catalog

enum MCPServerCatalog {

    static let entries: [MCPCatalogEntry] = [
        // ── Notion ──────────────────────────────────────────────
        MCPCatalogEntry(
            id: "notion",
            name: "Notion",
            description: "Search, read, and create pages and databases in Notion",
            icon: "doc.text.fill",
            category: .productivity,
            transport: .stdio,
            command: "npx",
            args: ["-y", "@notionhq/notion-mcp-server"],
            url: nil,
            credentials: [
                MCPCredentialField(
                    id: "NOTION_TOKEN",
                    label: "Integration Token",
                    placeholder: "ntn_...",
                    isSecret: true,
                    isHeader: false
                )
            ],
            setupURL: "https://www.notion.so/profile/integrations",
            setupInstructions: "Create an Internal Integration at notion.so/profile/integrations, copy the token, and share your pages with the integration.",
            requiresPython: false
        ),

        // ── Gmail + Google Calendar ─────────────────────────────
        MCPCatalogEntry(
            id: "google-workspace",
            name: "Google Workspace",
            description: "Gmail, Google Calendar, and Drive — read emails, manage events, access files",
            icon: "envelope.fill",
            category: .productivity,
            transport: .stdio,
            command: "npx",
            args: ["-y", "mcp-google-workspace"],
            url: nil,
            credentials: [
                MCPCredentialField(
                    id: "GOOGLE_OAUTH_CREDENTIALS",
                    label: "OAuth Credentials Path",
                    placeholder: "/path/to/credentials.json",
                    isSecret: false,
                    isHeader: false
                )
            ],
            setupURL: "https://console.cloud.google.com/apis/credentials",
            setupInstructions: "Create an OAuth 2.0 Client ID in Google Cloud Console. Download the credentials JSON and provide the file path. Enable Gmail, Calendar, and Drive APIs.",
            requiresPython: false
        ),

        // ── GitHub ──────────────────────────────────────────────
        MCPCatalogEntry(
            id: "github",
            name: "GitHub",
            description: "Manage repos, issues, PRs, and code on GitHub",
            icon: "chevron.left.forwardslash.chevron.right",
            category: .development,
            transport: .stdio,
            command: "docker",
            args: ["run", "-i", "--rm", "-e", "GITHUB_PERSONAL_ACCESS_TOKEN", "ghcr.io/github/github-mcp-server"],
            url: nil,
            credentials: [
                MCPCredentialField(
                    id: "GITHUB_PERSONAL_ACCESS_TOKEN",
                    label: "Personal Access Token",
                    placeholder: "ghp_...",
                    isSecret: true,
                    isHeader: false
                )
            ],
            setupURL: "https://github.com/settings/tokens",
            setupInstructions: "Create a Personal Access Token (classic or fine-grained) at github.com/settings/tokens with the scopes you need (repo, issues, etc.).",
            requiresPython: false
        ),

        // ── Slack ───────────────────────────────────────────────
        MCPCatalogEntry(
            id: "slack",
            name: "Slack",
            description: "Read channels, post messages, and search conversations in Slack",
            icon: "number",
            category: .communication,
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-slack"],
            url: nil,
            credentials: [
                MCPCredentialField(
                    id: "SLACK_BOT_TOKEN",
                    label: "Bot Token",
                    placeholder: "xoxb-...",
                    isSecret: true,
                    isHeader: false
                ),
                MCPCredentialField(
                    id: "SLACK_TEAM_ID",
                    label: "Team ID",
                    placeholder: "T0123456789",
                    isSecret: false,
                    isHeader: false
                )
            ],
            setupURL: "https://api.slack.com/apps",
            setupInstructions: "Create a Slack App at api.slack.com/apps, add Bot Token Scopes (channels:read, chat:write, etc.), install to workspace, and copy the Bot User OAuth Token.",
            requiresPython: false
        ),

        // ── Linear ─────────────────────────────────────────────
        MCPCatalogEntry(
            id: "linear",
            name: "Linear",
            description: "Create and manage issues, projects, and cycles in Linear",
            icon: "line.3.crossed.swirl.circle.fill",
            category: .productivity,
            transport: .streamableHTTP,
            command: nil,
            args: nil,
            url: "https://mcp.linear.app/mcp",
            credentials: [],  // OAuth handled by Linear's hosted server
            setupURL: nil,
            setupInstructions: "Linear uses browser-based OAuth — no API key needed. You'll be prompted to log in when first connecting.",
            requiresPython: false
        ),

        // ── Figma ───────────────────────────────────────────────
        MCPCatalogEntry(
            id: "figma",
            name: "Figma",
            description: "Access Figma designs, components, and design tokens",
            icon: "paintbrush.fill",
            category: .design,
            transport: .streamableHTTP,
            command: nil,
            args: nil,
            url: "https://mcp.figma.com/mcp",
            credentials: [],  // OAuth handled by Figma's hosted server
            setupURL: nil,
            setupInstructions: "Figma uses browser-based authentication — no API key needed. You'll be prompted to log in when first connecting.",
            requiresPython: false
        ),

        // ── Zoom ────────────────────────────────────────────────
        MCPCatalogEntry(
            id: "zoom",
            name: "Zoom",
            description: "Schedule and manage Zoom meetings, check recordings",
            icon: "video.fill",
            category: .communication,
            transport: .stdio,
            command: "npx",
            args: ["-y", "@prathamesh0901/zoom-mcp-server"],
            url: nil,
            credentials: [
                MCPCredentialField(
                    id: "ZOOM_ACCOUNT_ID",
                    label: "Account ID",
                    placeholder: "Your Zoom Account ID",
                    isSecret: false,
                    isHeader: false
                ),
                MCPCredentialField(
                    id: "ZOOM_CLIENT_ID",
                    label: "Client ID",
                    placeholder: "Your Zoom Client ID",
                    isSecret: false,
                    isHeader: false
                ),
                MCPCredentialField(
                    id: "ZOOM_CLIENT_SECRET",
                    label: "Client Secret",
                    placeholder: "Your Zoom Client Secret",
                    isSecret: true,
                    isHeader: false
                )
            ],
            setupURL: "https://marketplace.zoom.us/develop/create",
            setupInstructions: "Create a Server-to-Server OAuth app at marketplace.zoom.us. Copy the Account ID, Client ID, and Client Secret.",
            requiresPython: false
        ),

        // ── Spotify ─────────────────────────────────────────────
        MCPCatalogEntry(
            id: "spotify",
            name: "Spotify",
            description: "Search music, control playback, manage playlists on Spotify",
            icon: "music.note",
            category: .media,
            transport: .stdio,
            command: "npx",
            args: ["-y", "@tbrgeek/spotify-mcp-server"],
            url: nil,
            credentials: [
                MCPCredentialField(
                    id: "SPOTIFY_CLIENT_ID",
                    label: "Client ID",
                    placeholder: "Your Spotify Client ID",
                    isSecret: false,
                    isHeader: false
                ),
                MCPCredentialField(
                    id: "SPOTIFY_CLIENT_SECRET",
                    label: "Client Secret",
                    placeholder: "Your Spotify Client Secret",
                    isSecret: true,
                    isHeader: false
                ),
                MCPCredentialField(
                    id: "SPOTIFY_REFRESH_TOKEN",
                    label: "Refresh Token",
                    placeholder: "Your Spotify Refresh Token",
                    isSecret: true,
                    isHeader: false
                )
            ],
            setupURL: "https://developer.spotify.com/dashboard",
            setupInstructions: "Create an app at developer.spotify.com/dashboard. Set redirect URI to http://localhost:8080/callback. You'll need to complete the OAuth flow once to get a refresh token.",
            requiresPython: false
        ),

        // ── Filesystem ─────────────────────────────────────────
        MCPCatalogEntry(
            id: "filesystem",
            name: "Filesystem",
            description: "Read, write, and search files in allowed directories",
            icon: "folder.fill",
            category: .productivity,
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "--"],
            url: nil,
            credentials: [
                MCPCredentialField(
                    id: "ALLOWED_DIRS",
                    label: "Allowed Directories",
                    placeholder: "/Users/you/Documents (comma-separated)",
                    isSecret: false,
                    isHeader: false
                )
            ],
            setupURL: nil,
            setupInstructions: "Enter the directories you want to grant access to, separated by commas. The server will only be able to read/write within these paths.",
            requiresPython: false
        ),
    ]

    /// Look up a catalog entry by ID.
    static func entry(for id: String) -> MCPCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// Group entries by category.
    static var byCategory: [(MCPAppCategory, [MCPCatalogEntry])] {
        MCPAppCategory.allCases.compactMap { cat in
            let items = entries.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }
}
