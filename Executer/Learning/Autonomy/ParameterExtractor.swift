import Foundation

/// Identifies variable vs constant parts of patterns.
/// Variable parts become template parameters.
enum ParameterExtractor {

    /// Analyze a set of similar patterns to find variable parts.
    static func extractParameters(from patterns: [WorkflowPattern]) -> [Int] {
        guard let first = patterns.first, patterns.count > 1 else { return [] }

        var variableIndices: [Int] = []

        for i in 0..<first.actions.count {
            // Check if this action's value varies across similar patterns
            let values = patterns.compactMap { p -> String? in
                guard i < p.actions.count else { return nil }
                return p.actions[i].elementValue
            }

            let uniqueValues = Set(values)
            if uniqueValues.count > 1 {
                variableIndices.append(i)
            }
        }

        return variableIndices
    }
}
