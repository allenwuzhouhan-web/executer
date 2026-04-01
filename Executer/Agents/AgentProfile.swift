import Foundation

/// A scoped agent profile that determines which tools, memory namespace,
/// system prompt, and model the LLM uses for a given domain.
struct AgentProfile: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String
    var systemPromptOverride: String?
    var allowedToolIDs: Set<String>?   // nil = all tools (general agent)
    var memoryNamespace: String
    var modelOverride: String?
    var maxTokenBudget: Int?
    var color: String                  // hex e.g. "#00C9A7"
    var icon: String                   // SF Symbol name
    var isBuiltIn: Bool
    var keywords: [String]             // fast routing keywords

    static func == (lhs: AgentProfile, rhs: AgentProfile) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Defaults

    static let general = AgentProfile(
        id: "general",
        displayName: "General",
        systemPromptOverride: nil,
        allowedToolIDs: nil,
        memoryNamespace: "general",
        modelOverride: nil,
        maxTokenBudget: nil,
        color: "#FFFFFF",
        icon: "sparkle",
        isBuiltIn: true,
        keywords: []
    )
}
