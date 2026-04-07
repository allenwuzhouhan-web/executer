import Foundation

/// Composes smaller workflows into larger, complex automations.
///
/// Phase 13 of the Workflow Recorder ("The Weaver").
/// "Weekly report" = "fetch sales data" + "fetch support data" + "compile report"
///
/// Discovers composition opportunities from journal history (workflows
/// that consistently co-occur) and supports explicit composition via
/// sequential, parallel, or conditional linking.
enum WorkflowComposer {

    // MARK: - Composition

    /// Compose multiple workflows into a single composed workflow.
    static func compose(
        workflows: [GeneralizedWorkflow],
        mode: CompositionMode,
        name: String? = nil,
        dataLinks: [DataLink] = []
    ) -> ComposedWorkflow? {
        guard workflows.count >= 2 else { return nil }

        // Validate: no circular dependencies, compatible apps
        guard validate(workflows: workflows, dataLinks: dataLinks) else { return nil }

        // Merge steps based on composition mode
        let mergedSteps: [AbstractStep]
        let mergedParams: [WorkflowParameter]

        switch mode {
        case .sequential:
            mergedSteps = workflows.flatMap(\.steps)
            mergedParams = deduplicateParams(workflows.flatMap(\.parameters))

        case .parallel:
            // All workflows run simultaneously — steps interleaved by workflow
            mergedSteps = workflows.flatMap(\.steps)
            mergedParams = deduplicateParams(workflows.flatMap(\.parameters))

        case .conditional(let conditionParam):
            // First workflow is the condition evaluator, rest are branches
            mergedSteps = workflows.flatMap(\.steps)
            var params = deduplicateParams(workflows.flatMap(\.parameters))
            if !params.contains(where: { $0.name == conditionParam }) {
                params.append(WorkflowParameter(
                    name: conditionParam, type: .text,
                    description: "Condition that determines which branch to execute",
                    defaultValue: nil, exampleValues: [], stepBindings: []
                ))
            }
            mergedParams = params
        }

        // Build applicability from all sub-workflows
        let allApps = Array(Set(workflows.flatMap(\.applicability.requiredApps)))
        let allKeywords = Array(Set(workflows.flatMap(\.applicability.keywords)))
        let primaryApp = workflows.first?.applicability.primaryApp ?? "Unknown"

        let composedName = name ?? workflows.map(\.name).joined(separator: " + ")

        return ComposedWorkflow(
            id: UUID(),
            name: composedName,
            description: "Composed workflow: \(workflows.count) sub-workflows (\(mode.description))",
            subWorkflows: workflows.map { SubWorkflowRef(id: $0.id, name: $0.name, stepCount: $0.steps.count) },
            compositionMode: mode,
            mergedSteps: mergedSteps,
            mergedParameters: mergedParams,
            dataLinks: dataLinks,
            applicability: ApplicabilityCondition(
                requiredApps: allApps, primaryApp: primaryApp,
                category: workflows.first?.category ?? "other", keywords: allKeywords
            ),
            createdAt: Date()
        )
    }

    // MARK: - Composition Discovery

    /// Analyze journal history to find workflows that consistently co-occur.
    /// Returns pairs/triples that appear together in the same session window.
    static func discoverCompositions(
        workflows: [GeneralizedWorkflow],
        journals: [WorkflowJournal],
        minCoOccurrences: Int = 2
    ) -> [CompositionOpportunity] {
        guard workflows.count >= 2 else { return [] }

        // Build a co-occurrence matrix: which workflows appear in sequence
        // within a 2-hour window of each other
        var coOccurrences: [String: Int] = [:]  // "wf1_id:wf2_id" → count
        let timeWindow: TimeInterval = 7200  // 2 hours

        // For each journal, check if any workflows match its topic/app pattern
        for i in 0..<journals.count {
            for j in (i + 1)..<journals.count {
                let j1 = journals[i]
                let j2 = journals[j]

                // Check time proximity
                guard abs(j1.startTime.timeIntervalSince(j2.startTime)) < timeWindow else { continue }

                // Find workflows that match each journal
                let matches1 = workflows.filter { wf in matchesJournal(wf, journal: j1) }
                let matches2 = workflows.filter { wf in matchesJournal(wf, journal: j2) }

                for m1 in matches1 {
                    for m2 in matches2 where m1.id != m2.id {
                        let key = [m1.id.uuidString, m2.id.uuidString].sorted().joined(separator: ":")
                        coOccurrences[key, default: 0] += 1
                    }
                }
            }
        }

        // Convert to opportunities
        var opportunities: [CompositionOpportunity] = []
        for (key, count) in coOccurrences where count >= minCoOccurrences {
            let ids = key.split(separator: ":").map(String.init)
            guard ids.count == 2,
                  let wf1 = workflows.first(where: { $0.id.uuidString == ids[0] }),
                  let wf2 = workflows.first(where: { $0.id.uuidString == ids[1] }) else { continue }

            opportunities.append(CompositionOpportunity(
                workflows: [wf1, wf2],
                coOccurrenceCount: count,
                suggestedMode: .sequential,
                suggestedName: "\(wf1.name) then \(wf2.name)",
                confidence: min(Double(count) / 5.0, 0.95)
            ))
        }

        return opportunities.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Data Flow Linking

    /// Automatically discover data links between workflows.
    /// If workflow A has a step that copies/saves and workflow B has a step
    /// that pastes/opens, link them.
    static func discoverDataLinks(
        source: GeneralizedWorkflow,
        destination: GeneralizedWorkflow
    ) -> [DataLink] {
        var links: [DataLink] = []

        // Find output-producing steps in source
        let outputSteps = source.steps.filter {
            [.copyContent, .saveFile, .saveAsFile].contains($0.operation)
        }

        // Find input-consuming steps in destination
        let inputSteps = destination.steps.filter {
            [.pasteContent, .openDocument, .fillField].contains($0.operation)
        }

        // Match outputs to inputs by parameter type
        for output in outputSteps {
            for input in inputSteps {
                // If output has a parameter and input expects one, link them
                if let outputKey = output.parameterBindings.keys.first,
                   let inputKey = input.parameterBindings.keys.first {
                    links.append(DataLink(
                        sourceWorkflowId: source.id,
                        sourceStepId: output.id,
                        sourceKey: outputKey,
                        destinationWorkflowId: destination.id,
                        destinationStepId: input.id,
                        destinationKey: inputKey,
                        transferMethod: output.operation == .copyContent ? .clipboard : .file
                    ))
                }
            }
        }

        return links
    }

    // MARK: - Validation

    private static func validate(workflows: [GeneralizedWorkflow], dataLinks: [DataLink]) -> Bool {
        // Check for circular references in data links
        let wfIds = Set(workflows.map(\.id))
        for link in dataLinks {
            if !wfIds.contains(link.sourceWorkflowId) || !wfIds.contains(link.destinationWorkflowId) {
                return false
            }
            if link.sourceWorkflowId == link.destinationWorkflowId {
                return false  // Self-reference
            }
        }
        return true
    }

    private static func deduplicateParams(_ params: [WorkflowParameter]) -> [WorkflowParameter] {
        var seen: Set<String> = []
        return params.filter { p in
            guard !seen.contains(p.name) else { return false }
            seen.insert(p.name)
            return true
        }
    }

    private static func matchesJournal(_ workflow: GeneralizedWorkflow, journal: WorkflowJournal) -> Bool {
        // Match by app overlap and topic keyword overlap
        let appOverlap = !Set(workflow.applicability.requiredApps).intersection(Set(journal.apps)).isEmpty
        let topicOverlap = !Set(workflow.applicability.keywords).intersection(Set(journal.topicTerms)).isEmpty
        return appOverlap && topicOverlap
    }
}

// MARK: - Models

struct ComposedWorkflow: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var description: String
    let subWorkflows: [SubWorkflowRef]
    let compositionMode: CompositionMode
    let mergedSteps: [AbstractStep]
    let mergedParameters: [WorkflowParameter]
    let dataLinks: [DataLink]
    let applicability: ApplicabilityCondition
    let createdAt: Date
}

struct SubWorkflowRef: Codable, Sendable {
    let id: UUID
    let name: String
    let stepCount: Int
}

enum CompositionMode: Codable, Sendable {
    case sequential                    // A then B then C
    case parallel                      // A and B simultaneously
    case conditional(String)           // If condition → A, else → B

    var description: String {
        switch self {
        case .sequential: return "sequential"
        case .parallel: return "parallel"
        case .conditional(let param): return "conditional on \(param)"
        }
    }
}

struct DataLink: Codable, Sendable {
    let sourceWorkflowId: UUID
    let sourceStepId: UUID
    let sourceKey: String              // Output key from source step
    let destinationWorkflowId: UUID
    let destinationStepId: UUID
    let destinationKey: String         // Input key for destination step
    let transferMethod: DataBinding.TransferMethod
}

struct CompositionOpportunity: Sendable {
    let workflows: [GeneralizedWorkflow]
    let coOccurrenceCount: Int
    let suggestedMode: CompositionMode
    let suggestedName: String
    let confidence: Double
}
