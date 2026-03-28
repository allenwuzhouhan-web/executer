import Foundation

/// Validates workflow templates for safety and completeness before execution.
enum WorkflowValidator {

    enum ValidationResult {
        case valid
        case invalid(String)
    }

    /// Validate a template.
    static func validate(_ template: WorkflowTemplate) -> ValidationResult {
        // Check non-empty
        guard !template.steps.isEmpty else {
            return .invalid("Template has no steps")
        }

        // Check all steps have valid tool names
        for step in template.steps {
            if step.toolName.isEmpty {
                return .invalid("Step '\(step.description)' has no tool name")
            }
        }

        // Check risk tier is within bounds
        if template.riskTier > 3 {
            return .invalid("Risk tier \(template.riskTier) exceeds maximum (3)")
        }

        // Check parameters are referenced in steps
        for param in template.parameters {
            let placeholder = "{{\(param.name)}}"
            let isReferenced = template.steps.contains { $0.argumentsTemplate.contains(placeholder) }
            if !isReferenced {
                return .invalid("Parameter '\(param.name)' is not referenced in any step")
            }
        }

        return .valid
    }
}
