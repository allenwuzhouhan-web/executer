import Foundation

/// Watches execution outcomes to learn from failures and improve templates.
final class ExecutionObserver {
    static let shared = ExecutionObserver()

    private init() {}

    /// Observe an execution result and extract learning.
    func observe(_ result: ExecutionResult, template: WorkflowTemplate) {
        if result.status == .failed {
            print("[ExecutionObserver] Template '\(template.name)' failed at step \(result.stepsCompleted + 1)/\(result.stepsTotal)")
            if let error = result.error {
                print("[ExecutionObserver] Error: \(error)")
            }
        }

        // Track success rates per template
        let recentResults = ExecutionLogger.shared.recentExecutions(limit: 50)
            .filter { $0.templateId == template.id }
        let successRate = recentResults.isEmpty ? 0 :
            Double(recentResults.filter { $0.status == .completed }.count) / Double(recentResults.count)

        print("[ExecutionObserver] Template '\(template.name)' success rate: \(String(format: "%.1f%%", successRate * 100))")
    }
}
