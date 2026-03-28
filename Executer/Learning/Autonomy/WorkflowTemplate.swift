import Foundation

/// A parameterized, executable automation template compiled from learned patterns.
struct WorkflowTemplate: Codable, Identifiable {
    let id: UUID
    var name: String                     // "Morning Email Check"
    var description: String
    var triggerPhrase: String?            // Natural language trigger
    var steps: [TemplateStep]
    var parameters: [TemplateParameter]
    var preconditions: [Precondition]
    var sourcePatternId: UUID?           // Which pattern this was compiled from
    var timesExecuted: Int = 0
    var successRate: Double = 0.0
    var riskTier: Int = 1                // 1=safe, 2=elevated, 3=critical
    var createdAt: Date
    var updatedAt: Date

    struct TemplateStep: Codable {
        let toolName: String             // e.g., "launch_app", "click_element", "type_text"
        let argumentsTemplate: String    // JSON with {{parameter}} placeholders
        let description: String
        var isReversible: Bool = false
        var rollbackCommand: String?
    }

    struct TemplateParameter: Codable {
        let name: String
        let type: String                 // "string", "number", "app_name"
        let description: String
        let defaultValue: String?
    }

    struct Precondition: Codable {
        let check: String               // "app_is_running", "file_exists"
        let value: String                // App name or file path
    }

    init(name: String, description: String, steps: [TemplateStep], parameters: [TemplateParameter] = []) {
        self.id = UUID()
        self.name = name
        self.description = description
        self.steps = steps
        self.parameters = parameters
        self.preconditions = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
