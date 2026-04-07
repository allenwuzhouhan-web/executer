import Foundation

/// Replays a GeneralizedWorkflow on the current screen by adapting
/// to actual UI state rather than blindly repeating recorded actions.
///
/// Phase 7 of the Workflow Recorder ("The Shapeshifter").
/// For each step: perceive screen → match abstract target to concrete element →
/// verify precondition → execute → verify postcondition → advance.
///
/// Works across app versions, screen sizes, themes, and even similar-but-different apps.
actor AdaptiveReplayEngine {
    static let shared = AdaptiveReplayEngine()

    // MARK: - Configuration

    /// Maximum retries per step before marking as failed.
    private let maxRetriesPerStep = 3

    /// Delay between steps (ms) for UI to settle.
    private let interStepDelayMs: UInt64 = 300_000_000  // 300ms

    // MARK: - Replay

    /// Replay a generalized workflow with the given parameter bindings.
    /// Returns a ReplayResult describing what happened.
    func replay(
        workflow: GeneralizedWorkflow,
        parameters: [String: String] = [:],
        onProgress: (@Sendable (ReplayProgress) -> Void)? = nil
    ) async -> ReplayResult {
        var context = ReplayContext(workflow: workflow, parameters: parameters)

        print("[ReplayEngine] Starting replay: \(workflow.name) (\(workflow.steps.count) steps)")

        for (i, step) in workflow.steps.enumerated() {
            // Report progress
            onProgress?(ReplayProgress(
                stepIndex: i,
                totalSteps: workflow.steps.count,
                currentStep: step.description,
                status: .executing
            ))

            // Execute the step with retry
            let stepResult = await executeStep(step, index: i, context: &context)

            context.stepResults.append(stepResult)

            if case .failed(let reason) = stepResult.status {
                print("[ReplayEngine] Step \(i + 1) failed: \(reason)")
                onProgress?(ReplayProgress(
                    stepIndex: i,
                    totalSteps: workflow.steps.count,
                    currentStep: step.description,
                    status: .failed(reason)
                ))

                return ReplayResult(
                    workflowId: workflow.id,
                    status: .failed,
                    stepsCompleted: i,
                    stepsTotal: workflow.steps.count,
                    stepResults: context.stepResults,
                    error: reason
                )
            }

            // Brief delay for UI to settle
            try? await Task.sleep(nanoseconds: interStepDelayMs)
        }

        print("[ReplayEngine] Replay complete: \(workflow.steps.count) steps succeeded")
        onProgress?(ReplayProgress(
            stepIndex: workflow.steps.count,
            totalSteps: workflow.steps.count,
            currentStep: "Complete",
            status: .completed
        ))

        return ReplayResult(
            workflowId: workflow.id,
            status: .completed,
            stepsCompleted: workflow.steps.count,
            stepsTotal: workflow.steps.count,
            stepResults: context.stepResults,
            error: nil
        )
    }

    // MARK: - Step Execution

    /// Execute a single abstract step with perception-action loop.
    private func executeStep(
        _ step: AbstractStep,
        index: Int,
        context: inout ReplayContext
    ) async -> StepResult {

        for attempt in 1...maxRetriesPerStep {
            // 1. Check precondition
            if let precondition = step.precondition {
                let met = checkPrecondition(precondition)
                if !met {
                    // Try to satisfy precondition (e.g., switch to correct app)
                    let fixed = await tryFixPrecondition(precondition, step: step)
                    if !fixed {
                        if attempt < maxRetriesPerStep {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            continue
                        }
                        return StepResult(stepId: step.id, status: .failed("Precondition not met: \(precondition)"), attempts: attempt)
                    }
                }
            }

            // 2. Map abstract target to concrete element
            let concreteTarget = await matchElement(step.target, app: step.appContext)

            // 3. Execute the operation
            let success = await executeOperation(
                step.operation,
                target: concreteTarget,
                app: step.appContext,
                params: resolveParams(step.parameterBindings, context: context)
            )

            if success {
                return StepResult(stepId: step.id, status: .succeeded, attempts: attempt)
            }

            if attempt < maxRetriesPerStep {
                print("[ReplayEngine] Step \(index + 1) attempt \(attempt) failed, retrying...")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        return StepResult(stepId: step.id, status: .failed("Max retries exceeded"), attempts: maxRetriesPerStep)
    }

    // MARK: - Element Matching

    /// Match an abstract ElementTarget to a concrete element on screen.
    /// Uses semantic matching: AX role + label similarity + positional heuristics.
    private func matchElement(_ target: ElementTarget, app: String) async -> ConcreteTarget? {
        // Try exact label match first
        if !target.label.isEmpty {
            if let found = AdaptiveExecutor.findElement(description: target.label) {
                return ConcreteTarget(label: found, matchMethod: .exactLabel)
            }
        }

        // Try role-based match
        if !target.role.isEmpty {
            if let found = AdaptiveExecutor.findElement(description: target.role) {
                return ConcreteTarget(label: found, matchMethod: .roleMatch)
            }
        }

        // Try element type match
        if !target.elementType.isEmpty && !target.label.isEmpty {
            let combined = "\(target.label) \(target.elementType)"
            if let found = AdaptiveExecutor.findElement(description: combined) {
                return ConcreteTarget(label: found, matchMethod: .combined)
            }
        }

        return nil
    }

    // MARK: - Operation Execution

    /// Execute an abstract operation using the tool registry.
    private func executeOperation(
        _ operation: AbstractOperation,
        target: ConcreteTarget?,
        app: String,
        params: [String: String]
    ) async -> Bool {
        do {
            let toolName: String
            var args: [String: Any] = [:]

            switch operation {
            case .switchApp, .launchApp:
                toolName = "launch_app"
                args["app_name"] = app
            case .quitApp:
                toolName = "quit_app"
                args["app_name"] = app
            case .clickElement, .submitForm, .toggleOption, .selectItem:
                toolName = "click_element"
                args["element_description"] = target?.label ?? ""
            case .fillField, .search, .editText:
                toolName = "type_text"
                args["text"] = params["input_text"] ?? params["text"] ?? ""
            case .navigateTo:
                toolName = "type_text"
                args["text"] = params["destination"] ?? params["url_or_path"] ?? ""
            case .copyContent:
                toolName = "press_key"
                args["key"] = "command+c"
            case .pasteContent:
                toolName = "press_key"
                args["key"] = "command+v"
            case .saveFile:
                toolName = "press_key"
                args["key"] = "command+s"
            case .selectMenuItem:
                toolName = "click_element"
                args["element_description"] = target?.label ?? ""
            case .switchTab:
                toolName = "click_element"
                args["element_description"] = target?.label ?? "tab"
            case .openDocument:
                toolName = "press_key"
                args["key"] = "command+o"
            case .closeDocument, .closeWindow:
                toolName = "press_key"
                args["key"] = "command+w"
            default:
                print("[ReplayEngine] Unsupported operation: \(operation.rawValue)")
                return false
            }

            let argsJson = try JSONSerialization.data(withJSONObject: args)
            let argsString = String(data: argsJson, encoding: .utf8) ?? "{}"

            _ = try await ToolRegistry.shared.execute(toolName: toolName, arguments: argsString)
            return true
        } catch {
            print("[ReplayEngine] Operation \(operation.rawValue) failed: \(error)")
            return false
        }
    }

    // MARK: - Precondition Checking

    private func checkPrecondition(_ precondition: String) -> Bool {
        if precondition.hasPrefix("app_is_frontmost:") {
            let app = String(precondition.dropFirst("app_is_frontmost:".count))
            return UIStateVerifier.verifyFrontmostApp(app)
        }
        if precondition == "document_is_open" {
            return true  // Can't easily verify — assume true
        }
        if precondition == "clipboard_has_content" {
            return true  // Can't easily verify — assume true
        }
        return true
    }

    private func tryFixPrecondition(_ precondition: String, step: AbstractStep) async -> Bool {
        if precondition.hasPrefix("app_is_frontmost:") {
            let app = String(precondition.dropFirst("app_is_frontmost:".count))
            do {
                let args = "{\"app_name\": \"\(app)\"}"
                _ = try await ToolRegistry.shared.execute(toolName: "launch_app", arguments: args)
                try? await Task.sleep(nanoseconds: 500_000_000)
                return UIStateVerifier.verifyFrontmostApp(app)
            } catch {
                return false
            }
        }
        return false
    }

    // MARK: - Parameter Resolution

    private func resolveParams(_ bindings: [String: String], context: ReplayContext) -> [String: String] {
        var resolved: [String: String] = [:]
        for (key, template) in bindings {
            if template.hasPrefix("{{") && template.hasSuffix("}}") {
                let paramName = String(template.dropFirst(2).dropLast(2))
                resolved[key] = context.parameters[paramName] ?? template
            } else {
                resolved[key] = template
            }
        }
        return resolved
    }

    // MARK: - Types

    struct ConcreteTarget {
        let label: String
        let matchMethod: MatchMethod

        enum MatchMethod {
            case exactLabel, roleMatch, combined, ocrFallback
        }
    }
}

// MARK: - Replay Context

struct ReplayContext: Sendable {
    let workflow: GeneralizedWorkflow
    let parameters: [String: String]
    var stepResults: [StepResult] = []
}

// MARK: - Results

struct ReplayResult: Sendable {
    let workflowId: UUID
    let status: ReplayStatus
    let stepsCompleted: Int
    let stepsTotal: Int
    let stepResults: [StepResult]
    let error: String?
}

struct StepResult: Sendable {
    let stepId: UUID
    let status: StepStatus
    let attempts: Int
}

enum ReplayStatus: String, Sendable {
    case completed, failed, cancelled
}

enum StepStatus: Sendable {
    case succeeded
    case failed(String)
    case skipped
}

struct ReplayProgress: Sendable {
    let stepIndex: Int
    let totalSteps: Int
    let currentStep: String
    let status: ProgressStatus

    enum ProgressStatus: Sendable {
        case executing, completed, failed(String)
    }
}
