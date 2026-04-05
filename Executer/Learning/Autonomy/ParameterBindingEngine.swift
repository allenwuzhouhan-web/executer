import Foundation

/// Manages parameter binding at replay time and discovers new parameters
/// through cross-execution diffing.
///
/// Phase 8 of the Workflow Recorder ("The Alchemist").
///
/// Responsibilities:
/// 1. At replay time: identify unbound parameters, prompt for values, suggest defaults
/// 2. Cross-execution diffing: when the same workflow is journaled multiple times,
///    diff concrete values to discover new variable slots
/// 3. Batch binding: "use this filename pattern for all 50 files"
/// 4. Type inference: classify parameter types using EntityExtractor + heuristics
actor ParameterBindingEngine {
    static let shared = ParameterBindingEngine()

    // MARK: - Binding Resolution

    /// Resolve all parameters for a workflow before replay.
    /// Returns a complete parameter map ready for AdaptiveReplayEngine.
    func resolveParameters(
        workflow: GeneralizedWorkflow,
        userProvided: [String: String] = [:]
    ) -> ParameterResolution {
        var bound: [String: String] = [:]
        var unbound: [UnboundParameter] = []

        for param in workflow.parameters {
            if let value = userProvided[param.name] {
                // User explicitly provided this value
                bound[param.name] = value
            } else if let defaultValue = param.defaultValue {
                // Use default value
                bound[param.name] = defaultValue
            } else if let suggested = suggestValue(for: param) {
                // Suggest from recent usage
                bound[param.name] = suggested
            } else {
                // Unbound — needs user input
                unbound.append(UnboundParameter(
                    name: param.name,
                    type: param.type,
                    description: param.description,
                    suggestions: param.exampleValues
                ))
            }
        }

        return ParameterResolution(
            bound: bound,
            unbound: unbound,
            isComplete: unbound.isEmpty
        )
    }

    /// Generate a prompt asking the user for unbound parameters.
    func generatePrompt(for resolution: ParameterResolution, workflowName: String) -> String {
        guard !resolution.isComplete else {
            return "All parameters resolved for '\(workflowName)'. Ready to replay."
        }

        var lines = ["To replay '\(workflowName)', I need these values:"]
        for param in resolution.unbound {
            var line = "  - **\(param.name)** (\(param.type.rawValue)): \(param.description)"
            if !param.suggestions.isEmpty {
                line += " [suggestions: \(param.suggestions.prefix(3).joined(separator: ", "))]"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Batch Binding

    /// Create parameter bindings for batch execution over a list of items.
    /// The iterationParam is bound to each item in sequence.
    func createBatchBindings(
        workflow: GeneralizedWorkflow,
        iterationParam: String,
        items: [String],
        fixedParams: [String: String] = [:]
    ) -> [BatchBinding] {
        items.map { item in
            var params = fixedParams
            params[iterationParam] = item
            return BatchBinding(
                itemValue: item,
                parameters: params
            )
        }
    }

    /// Identify which parameter is the likely iteration variable
    /// (for "do that for all 50 files" scenarios).
    func identifyIterationParameter(workflow: GeneralizedWorkflow) -> WorkflowParameter? {
        // Heuristic: the iteration variable is usually a filepath, text, or url parameter
        // that appears in the most steps
        let candidates = workflow.parameters.filter {
            [.filepath, .text, .url].contains($0.type)
        }

        // Prefer filepath params (most common batch target)
        if let filepath = candidates.first(where: { $0.type == .filepath }) {
            return filepath
        }

        // Otherwise, the parameter used in the most steps
        return candidates.max(by: { $0.stepBindings.count < $1.stepBindings.count })
    }

    // MARK: - Cross-Execution Diffing

    /// Compare two journals that represent the same workflow and discover
    /// new parameters (values that changed between executions).
    func diffForParameters(
        journal1: WorkflowJournal,
        journal2: WorkflowJournal,
        existingWorkflow: GeneralizedWorkflow
    ) -> [WorkflowParameter] {
        var newParams: [WorkflowParameter] = []
        let existingNames = Set(existingWorkflow.parameters.map(\.name))

        // Compare entries pairwise (by position — assumes similar structure)
        let minCount = min(journal1.entries.count, journal2.entries.count)

        for i in 0..<minCount {
            let e1 = journal1.entries[i]
            let e2 = journal2.entries[i]

            // Same operation type but different element context = potential parameter
            if e1.intentCategory == e2.intentCategory
                && e1.appContext == e2.appContext
                && e1.elementContext != e2.elementContext {
                let paramName = "param_\(i)_context"
                if !existingNames.contains(paramName) {
                    let type = inferType(from: [e1.elementContext, e2.elementContext])
                    newParams.append(WorkflowParameter(
                        name: paramName,
                        type: type,
                        description: "Variable element at step \(i + 1)",
                        defaultValue: e2.elementContext,
                        exampleValues: [e1.elementContext, e2.elementContext],
                        stepBindings: []
                    ))
                }
            }

            // Same operation but different topic terms = different subject matter
            if e1.intentCategory == e2.intentCategory {
                let diff = Set(e2.topicTerms).subtracting(Set(e1.topicTerms))
                if !diff.isEmpty && diff.count <= 3 {
                    let paramName = "param_\(i)_topic"
                    if !existingNames.contains(paramName) {
                        newParams.append(WorkflowParameter(
                            name: paramName,
                            type: .text,
                            description: "Variable topic at step \(i + 1)",
                            defaultValue: diff.first,
                            exampleValues: Array(diff),
                            stepBindings: []
                        ))
                    }
                }
            }
        }

        return newParams
    }

    // MARK: - Value Suggestion

    /// Suggest a value for a parameter based on recent usage and context.
    private func suggestValue(for param: WorkflowParameter) -> String? {
        // Return the most recent example value if available
        param.exampleValues.last
    }

    // MARK: - Type Inference

    /// Infer parameter type from observed values.
    private func inferType(from values: [String]) -> WorkflowParameter.ParameterType {
        for value in values {
            // Check for file paths
            if (value.contains("/") || value.contains(".")) && !value.contains(" ") {
                if value.hasPrefix("/") || value.hasPrefix("~") { return .filepath }
                if value.contains("://") { return .url }
                // Extension-like pattern
                let ext = (value as NSString).pathExtension
                if !ext.isEmpty && ext.count <= 5 { return .filepath }
            }

            // Check for email
            if value.contains("@") && value.contains(".") { return .email }

            // Check for numbers
            if Double(value) != nil { return .number }

            // Check for dates using entity extraction
            let entities = EntityExtractor.extract(from: value)
            if entities.contains(where: { $0.type == .date }) { return .date }
        }

        return .text
    }

    // MARK: - Types

    struct ParameterResolution: Sendable {
        let bound: [String: String]         // Parameters with values
        let unbound: [UnboundParameter]     // Parameters needing user input
        let isComplete: Bool                // True if all params are bound
    }

    struct UnboundParameter: Sendable {
        let name: String
        let type: WorkflowParameter.ParameterType
        let description: String
        let suggestions: [String]
    }

    struct BatchBinding: Sendable {
        let itemValue: String               // The iteration item
        let parameters: [String: String]    // Full parameter map for this item
    }
}
