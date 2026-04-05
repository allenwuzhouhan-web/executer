import Foundation

/// Converts learned WorkflowPatterns into executable WorkflowTemplates.
enum WorkflowCompiler {

    /// Compile a pattern into an executable template.
    static func compile(_ pattern: WorkflowPattern) -> WorkflowTemplate? {
        guard !pattern.actions.isEmpty else { return nil }

        var steps: [WorkflowTemplate.TemplateStep] = []
        var parameters: [WorkflowTemplate.TemplateParameter] = []
        var maxRisk = 1

        for action in pattern.actions {
            let (step, param, risk) = compileAction(action)
            steps.append(step)
            if let param = param { parameters.append(param) }
            maxRisk = max(maxRisk, risk)
        }

        var template = WorkflowTemplate(
            name: pattern.name,
            description: "Compiled from observed pattern (\(pattern.frequency)x)",
            steps: steps,
            parameters: parameters
        )
        template.sourcePatternId = pattern.id
        template.riskTier = maxRisk

        return template
    }

    /// Compile a single action into a template step.
    private static func compileAction(_ action: WorkflowPattern.PatternAction) -> (WorkflowTemplate.TemplateStep, WorkflowTemplate.TemplateParameter?, Int) {
        var risk = 1
        let step: WorkflowTemplate.TemplateStep
        var param: WorkflowTemplate.TemplateParameter?

        switch action.type {
        case .click:
            step = WorkflowTemplate.TemplateStep(
                toolName: "click_element",
                argumentsTemplate: "{\"element_description\": \"\(action.elementTitle)\"}",
                description: "Click \(action.elementTitle) [\(action.elementRole)]"
            )
        case .textEdit:
            let paramName = "text_\(action.elementTitle.prefix(10).filter(\.isLetter))"
            step = WorkflowTemplate.TemplateStep(
                toolName: "type_text",
                argumentsTemplate: "{\"text\": \"{{\(paramName)}}\"}",
                description: "Type text in \(action.elementTitle)"
            )
            param = WorkflowTemplate.TemplateParameter(
                name: paramName, type: "string",
                description: "Text to type in \(action.elementTitle)",
                defaultValue: action.elementValue.isEmpty ? nil : action.elementValue
            )
        case .menuSelect:
            step = WorkflowTemplate.TemplateStep(
                toolName: "click_element",
                argumentsTemplate: "{\"element_description\": \"\(action.elementTitle)\"}",
                description: "Select menu: \(action.elementTitle)"
            )
        case .windowOpen:
            step = WorkflowTemplate.TemplateStep(
                toolName: "launch_app",
                argumentsTemplate: "{\"app_name\": \"\(action.elementTitle)\"}",
                description: "Open \(action.elementTitle)"
            )
        case .focus:
            step = WorkflowTemplate.TemplateStep(
                toolName: "click_element",
                argumentsTemplate: "{\"element_description\": \"\(action.elementTitle)\"}",
                description: "Focus on \(action.elementTitle)"
            )
        case .tabSwitch:
            step = WorkflowTemplate.TemplateStep(
                toolName: "click_element",
                argumentsTemplate: "{\"element_description\": \"\(action.elementTitle)\"}",
                description: "Switch to tab \(action.elementTitle)"
            )
        case .textSelect:
            step = WorkflowTemplate.TemplateStep(
                toolName: "click_element",
                argumentsTemplate: "{\"element_description\": \"\(action.elementTitle)\"}",
                description: "Select text in \(action.elementTitle)"
            )
        }

        return (step, param, risk)
    }
}
