import Foundation

/// Tool that lets the LLM recall and describe previously observed workflows.
/// Registered in ToolRegistry as "recall_workflow".
///
/// The LLM calls this when the user says things like:
/// "do that thing I did with the invoices"
/// "repeat what I did yesterday in Excel"
/// "find my workflow for filing expenses"
struct RecallWorkflowTool: ToolDefinition {
    let name = "recall_workflow"
    let description = """
    Search for a previously observed user workflow by natural language description.
    Use this when the user asks to repeat, redo, or recall something they did before.
    Returns matching workflows with descriptions and step summaries.
    """

    let parameters: [String: Any] = JSONSchema.object(
        properties: [
            "query": JSONSchema.string(description: "Natural language description of the workflow to find. Include any time references (e.g., 'yesterday', 'last Tuesday') and topic keywords (e.g., 'invoices', 'filing', 'presentation')."),
            "limit": JSONSchema.integer(description: "Maximum number of results to return", minimum: 1, maximum: 10),
        ],
        required: ["query"]
    )

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let limit = optionalInt("limit", from: args) ?? 5

        let results = await WorkflowRecaller.recall(query: query, limit: limit)

        if results.isEmpty {
            return "No matching workflows found for '\(query)'. The user may not have performed this workflow recently, or the workflow recorder hasn't observed it yet."
        }

        if results.count == 1 {
            let r = results[0]
            return formatSingleResult(r)
        }

        // Multiple results — provide disambiguation
        return WorkflowRecaller.disambiguate(results)
    }

    private func formatSingleResult(_ r: WorkflowRecaller.RecallResult) -> String {
        let wf = r.workflow
        var lines = ["Found workflow: **\(wf.name)**"]
        lines.append("Description: \(wf.description)")
        lines.append("Apps: \(wf.applicability.requiredApps.joined(separator: ", "))")
        lines.append("Steps: \(wf.steps.count)")
        lines.append("Category: \(wf.category)")

        // Show first few steps
        if !wf.steps.isEmpty {
            lines.append("Preview:")
            for (i, step) in wf.steps.prefix(5).enumerated() {
                lines.append("  \(i + 1). \(step.description)")
            }
            if wf.steps.count > 5 {
                lines.append("  ... and \(wf.steps.count - 5) more steps")
            }
        }

        // Show parameters if any
        if !wf.parameters.isEmpty {
            lines.append("Parameters needed: \(wf.parameters.map { "\($0.name) (\($0.type.rawValue))" }.joined(separator: ", "))")
        }

        lines.append("Match confidence: \(String(format: "%.0f%%", r.score * 100))")
        return lines.joined(separator: "\n")
    }
}
