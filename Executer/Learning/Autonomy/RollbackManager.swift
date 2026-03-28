import Foundation

/// Tracks reversible actions and rolls back on failure.
enum RollbackManager {

    /// Attempt to roll back completed steps of a failed execution.
    static func rollback(template: WorkflowTemplate, stepsCompleted: Int) async -> Bool {
        // Roll back in reverse order
        for i in stride(from: stepsCompleted - 1, through: 0, by: -1) {
            let step = template.steps[i]
            guard step.isReversible, let rollbackCmd = step.rollbackCommand else { continue }

            print("[Rollback] Reversing step \(i + 1): \(step.description)")
            // Execute rollback command (placeholder)
            _ = rollbackCmd
        }
        return true
    }
}
