import Foundation

// MARK: - Phase 4-10 Tools

/// Tool to get predictions about user's next actions.
struct GetPredictionsTool: ToolDefinition {
    let name = "get_predictions"
    let description = "Get predictions about what the user will do next, based on time patterns, action sequences, and goals."
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let predictions = PredictionEngine.shared.predict()
        guard !predictions.isEmpty else { return "No predictions available." }
        var lines = ["## Predictions:"]
        for pred in predictions.prefix(5) {
            lines.append("- \(pred.predictedAction) (confidence: \(String(format: "%.0f%%", pred.confidence * 100))) — \(pred.reasoning)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Tool to get detected routines.
struct GetRoutinesTool: ToolDefinition {
    let name = "get_routines"
    let description = "Get the user's detected daily routines — recurring time-based patterns like 'opens email at 9am'."
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let routines = PredictionEngine.shared.getRoutines()
        guard !routines.isEmpty else { return "No routines detected yet." }
        var lines = ["## Detected Routines:"]
        for r in routines.prefix(10) {
            lines.append("- \(r.description) (confidence: \(String(format: "%.0f%%", r.confidence * 100)))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Tool to list workflow templates.
struct ListWorkflowTemplatesTool: ToolDefinition {
    let name = "list_workflow_templates"
    let description = "List all learned workflow automation templates."
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let templates = TemplateLibrary.shared.all()
        guard !templates.isEmpty else { return "No workflow templates yet." }
        var lines = ["## Workflow Templates:"]
        for t in templates {
            lines.append("- **\(t.name)** (\(t.steps.count) steps, executed \(t.timesExecuted)x, \(String(format: "%.0f%%", t.successRate * 100)) success)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Tool to get the autonomy dashboard.
struct GetAutonomyStatusTool: ToolDefinition {
    let name = "get_autonomy_status"
    let description = "Get the full autonomy dashboard — learning stats, goals, templates, execution history, prediction accuracy."
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        return AutonomyDashboard.statusReport()
    }
}

/// Tool to get today's work plan.
struct GetDayPlanTool: ToolDefinition {
    let name = "get_day_plan"
    let description = "Get a suggested work plan for today based on goals, calendar, and routines."
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        return DayPlanner.generatePlan()
    }
}

/// Tool to compile a pattern into a workflow template.
struct CompilePatternTool: ToolDefinition {
    let name = "compile_pattern_to_template"
    let description = "Compile a learned pattern into an executable workflow template."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "app_name": JSONSchema.string(description: "App name to compile patterns from"),
        ], required: ["app_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let appName = try requiredString("app_name", from: args)

        let patterns = LearningDatabase.shared.topPatterns(forApp: appName, limit: 5)
        guard !patterns.isEmpty else { return "No patterns found for \(appName)." }

        var compiled = 0
        for pattern in patterns {
            if let template = WorkflowCompiler.compile(pattern) {
                TemplateLibrary.shared.save(template)
                compiled += 1
            }
        }

        return "Compiled \(compiled) patterns into workflow templates for \(appName)."
    }
}
