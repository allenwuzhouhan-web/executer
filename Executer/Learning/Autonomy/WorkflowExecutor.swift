import Foundation

/// Executes workflow template steps sequentially with error handling.
final class WorkflowExecutor {
    static let shared = WorkflowExecutor()

    private init() {}

    /// Execute a workflow template.
    func execute(template: WorkflowTemplate, parameters: [String: String] = [:]) async -> ExecutionResult {
        var stepsCompleted = 0
        var results: [String] = []

        for step in template.steps {
            // Check safety
            if SafetyGuard.requiresApproval(step) {
                let approved = await ApprovalGateway.shared.requestApproval(
                    description: "Workflow '\(template.name)' wants to: \(step.description)"
                )
                guard approved else {
                    return ExecutionResult(
                        templateId: template.id,
                        status: .cancelled,
                        stepsCompleted: stepsCompleted,
                        stepsTotal: template.steps.count,
                        error: "User denied approval for: \(step.description)"
                    )
                }
            }

            // Substitute parameters
            var args = step.argumentsTemplate
            for (key, value) in parameters {
                args = args.replacingOccurrences(of: "{{\(key)}}", with: value)
            }

            // Execute the step (placeholder — actual tool execution via ToolRegistry)
            do {
                let result = try await executeStep(toolName: step.toolName, arguments: args)
                results.append(result)
                stepsCompleted += 1
            } catch {
                return ExecutionResult(
                    templateId: template.id,
                    status: .failed,
                    stepsCompleted: stepsCompleted,
                    stepsTotal: template.steps.count,
                    error: error.localizedDescription
                )
            }
        }

        return ExecutionResult(
            templateId: template.id,
            status: .completed,
            stepsCompleted: stepsCompleted,
            stepsTotal: template.steps.count,
            resultSummary: results.joined(separator: "\n")
        )
    }

    private func executeStep(toolName: String, arguments: String) async throws -> String {
        // Delegate to ToolRegistry for actual execution
        // This is a bridge — the actual tool execution goes through the existing pipeline
        return "Executed \(toolName)"
    }
}

/// Result of a workflow execution.
struct ExecutionResult: Codable {
    let templateId: UUID
    let status: ExecutionStatus
    let stepsCompleted: Int
    let stepsTotal: Int
    let error: String?
    let resultSummary: String?
    let timestamp: Date

    enum ExecutionStatus: String, Codable {
        case completed, failed, cancelled, rolledBack
    }

    init(templateId: UUID, status: ExecutionStatus, stepsCompleted: Int, stepsTotal: Int, error: String? = nil, resultSummary: String? = nil) {
        self.templateId = templateId
        self.status = status
        self.stepsCompleted = stepsCompleted
        self.stepsTotal = stepsTotal
        self.error = error
        self.resultSummary = resultSummary
        self.timestamp = Date()
    }
}
