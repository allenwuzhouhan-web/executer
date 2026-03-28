import Foundation

/// Manages the trigger → approve → execute → log lifecycle for autonomous workflows.
final class AutonomyOrchestrator {
    static let shared = AutonomyOrchestrator()

    private var hourlyActionCount = 0
    private var consecutiveFailures = 0
    private var isPaused = false
    private var lastHourReset = Date()

    private init() {}

    /// Attempt to trigger a workflow template.
    func trigger(template: WorkflowTemplate, parameters: [String: String] = [:]) async -> ExecutionResult? {
        // Check circuit breakers
        guard !isPaused else {
            print("[Autonomy] Paused after consecutive failures")
            return nil
        }

        resetHourlyCountIfNeeded()
        guard SafetyGuard.isWithinHourlyLimit(actionCount: hourlyActionCount) else {
            print("[Autonomy] Hourly action limit reached")
            return nil
        }

        // Validate template
        let validation = WorkflowValidator.validate(template)
        if case .invalid(let reason) = validation {
            print("[Autonomy] Template invalid: \(reason)")
            return nil
        }

        // Request approval
        let description = "Execute workflow '\(template.name)' (\(template.steps.count) steps)"
        let approved = await ApprovalGateway.shared.requestApproval(description: description)
        guard approved else { return nil }

        // Execute
        let result = await WorkflowExecutor.shared.execute(template: template, parameters: parameters)

        // Log
        ExecutionLogger.shared.record(result)
        hourlyActionCount += template.steps.count

        // Update failure tracking
        if result.status == .completed {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= SafetyGuard.maxConsecutiveFailures {
                isPaused = true
                print("[Autonomy] Auto-paused after \(consecutiveFailures) consecutive failures")
            }
        }

        // Update template stats
        var updatedTemplate = template
        updatedTemplate.timesExecuted += 1
        let allResults = ExecutionLogger.shared.recentExecutions(limit: 100)
            .filter { $0.templateId == template.id }
        let successes = allResults.filter { $0.status == .completed }.count
        updatedTemplate.successRate = allResults.isEmpty ? 0 : Double(successes) / Double(allResults.count)
        updatedTemplate.updatedAt = Date()
        TemplateLibrary.shared.save(updatedTemplate)

        return result
    }

    /// Resume after pause.
    func resume() {
        isPaused = false
        consecutiveFailures = 0
    }

    /// Emergency stop.
    func stop() {
        isPaused = true
    }

    private func resetHourlyCountIfNeeded() {
        if Date().timeIntervalSince(lastHourReset) > 3600 {
            hourlyActionCount = 0
            lastHourReset = Date()
        }
    }
}
