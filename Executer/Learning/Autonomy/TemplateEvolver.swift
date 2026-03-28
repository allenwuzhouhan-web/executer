import Foundation

/// Modifies templates based on execution outcomes.
/// Failed steps can be updated with working alternatives.
enum TemplateEvolver {

    /// Evolve a template based on execution history.
    static func evolve(template: WorkflowTemplate) -> WorkflowTemplate {
        var evolved = template

        let results = ExecutionLogger.shared.recentExecutions(limit: 20)
            .filter { $0.templateId == template.id }

        // If recent failure rate > 50%, mark for review
        let failures = results.filter { $0.status == .failed }
        if !results.isEmpty && Double(failures.count) / Double(results.count) > 0.5 {
            evolved.description += " [NEEDS REVIEW: high failure rate]"
        }

        evolved.updatedAt = Date()
        return evolved
    }
}
