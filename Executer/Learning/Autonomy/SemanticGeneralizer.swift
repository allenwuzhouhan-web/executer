import Foundation

/// Transforms a completed WorkflowJournal into a GeneralizedWorkflow.
///
/// This is Phase 4 of the Workflow Recorder ("The Abstractor").
/// The generalization pipeline:
///   1. Filter: remove noisy/low-confidence entries
///   2. Abstract: classify each entry into an AbstractStep via ActionAbstractor
///   3. Collapse: merge consecutive redundant steps (e.g., multiple focus → single navigate)
///   4. Parameterize: identify variable slots using structural heuristics + entity extraction
///   5. Name & describe: generate a human-readable name and description
///   6. Classify: assign topic category and applicability conditions
///   7. Score: compute generalization confidence
enum SemanticGeneralizer {

    /// Minimum entries for a journal to be worth generalizing.
    private static let minimumEntries = 3

    /// Minimum confidence to keep an entry during filtering.
    private static let entryConfidenceThreshold = 0.3

    /// Maximum steps in a generalized workflow (prevents bloat).
    private static let maxSteps = 50

    // MARK: - Main Entry Point

    /// Generalize a completed journal into a GeneralizedWorkflow.
    /// Returns nil if the journal is too short or too noisy to generalize.
    static func generalize(_ journal: WorkflowJournal) -> GeneralizedWorkflow? {
        guard journal.entries.count >= minimumEntries else {
            print("[Generalizer] Skipping journal \(journal.id) — too few entries (\(journal.entries.count))")
            return nil
        }

        // Step 1: Filter noisy entries
        let filtered = filterEntries(journal.entries)
        guard filtered.count >= minimumEntries else { return nil }

        // Step 2: Abstract each entry into an AbstractStep
        var abstractSteps = filtered.map { ActionAbstractor.abstract($0) }

        // Step 3: Collapse redundant consecutive steps
        abstractSteps = collapseRedundant(abstractSteps)

        // Step 4: Cap at max steps
        if abstractSteps.count > maxSteps {
            abstractSteps = Array(abstractSteps.prefix(maxSteps))
        }

        // Step 5: Discover parameters
        let parameters = discoverParameters(from: filtered, steps: abstractSteps)

        // Step 6: Generate name and description
        let name = generateName(journal: journal, steps: abstractSteps)
        let description = generateDescription(journal: journal, steps: abstractSteps)

        // Step 7: Build applicability conditions
        let applicability = buildApplicability(journal: journal)

        // Step 8: Classify topic
        let category = classifyCategory(journal: journal)

        // Step 9: Score confidence
        let confidence = scoreConfidence(journal: journal, steps: abstractSteps, filtered: filtered)

        let workflow = GeneralizedWorkflow(
            name: name,
            description: description,
            steps: abstractSteps,
            parameters: parameters,
            applicability: applicability,
            sourceJournalId: journal.id,
            category: category,
            confidence: confidence
        )

        print("[Generalizer] Created workflow: \(workflow.summary)")
        return workflow
    }

    // MARK: - Step 1: Filtering

    /// Remove noisy, low-confidence, and redundant entries.
    private static func filterEntries(_ entries: [JournalEntry]) -> [JournalEntry] {
        entries.filter { entry in
            // Skip low-confidence entries
            guard entry.confidence >= entryConfidenceThreshold else { return false }

            // Skip empty semantic actions
            guard !entry.semanticAction.isEmpty else { return false }

            // Skip pure navigation noise (focus on generic elements)
            if entry.intentCategory == "navigating" && entry.elementContext.isEmpty {
                return false
            }

            return true
        }
    }

    // MARK: - Step 3: Collapse Redundant Steps

    /// Merge consecutive steps that are logically the same action.
    /// e.g., multiple focus→focus→click on the same app = single click.
    /// e.g., consecutive text edits in the same field = single fillField.
    private static func collapseRedundant(_ steps: [AbstractStep]) -> [AbstractStep] {
        guard steps.count > 1 else { return steps }

        var result: [AbstractStep] = [steps[0]]

        for i in 1..<steps.count {
            let current = steps[i]
            let previous = result.last!

            // Collapse consecutive clicks on the same element
            if current.operation == previous.operation
                && current.appContext == previous.appContext
                && current.target.role == previous.target.role
                && current.operation == .clickElement {
                continue  // Skip duplicate
            }

            // Collapse focus→click on same element (keep only the click)
            if previous.operation == .clickElement
                && current.operation == .fillField
                && current.appContext == previous.appContext {
                // Focus then fill = just fill
                result[result.count - 1] = current
                continue
            }

            // Collapse consecutive fillField on same field (keep last)
            if current.operation == .fillField
                && previous.operation == .fillField
                && current.appContext == previous.appContext
                && current.target.role == previous.target.role {
                result[result.count - 1] = current
                continue
            }

            result.append(current)
        }

        return result
    }

    // MARK: - Step 5: Parameter Discovery

    /// Identify parameters — fields that are likely variable across instances.
    /// Uses structural heuristics: text inputs, file names, URLs are likely parameters.
    private static func discoverParameters(
        from entries: [JournalEntry],
        steps: [AbstractStep]
    ) -> [WorkflowParameter] {
        var parameters: [WorkflowParameter] = []
        var parameterNames: Set<String> = []

        for (i, step) in steps.enumerated() {
            for (hintName, _) in step.parameterBindings {
                // Don't create duplicate parameters
                guard !parameterNames.contains(hintName) else { continue }
                parameterNames.insert(hintName)

                let type = inferParameterType(name: hintName, step: step, entry: i < entries.count ? entries[i] : nil)

                parameters.append(WorkflowParameter(
                    name: hintName,
                    type: type,
                    description: describeParameter(name: hintName, step: step),
                    defaultValue: nil,
                    exampleValues: [],
                    stepBindings: [step.id]
                ))
            }
        }

        return parameters
    }

    /// Infer the parameter type from its name and context.
    private static func inferParameterType(
        name: String,
        step: AbstractStep,
        entry: JournalEntry?
    ) -> WorkflowParameter.ParameterType {
        let nameLower = name.lowercased()

        if nameLower.contains("file") || nameLower.contains("path") || nameLower.contains("document") {
            return .filepath
        }
        if nameLower.contains("url") || nameLower.contains("link") || nameLower.contains("address") {
            return .url
        }
        if nameLower.contains("email") { return .email }
        if nameLower.contains("date") || nameLower.contains("time") { return .date }
        if nameLower.contains("app") { return .appName }
        if nameLower.contains("menu") { return .menuItem }

        // Check entity extraction on the entry's topic terms
        if let entry = entry {
            let entities = EntityExtractor.extract(from: entry.topicTerms.joined(separator: " "))
            if entities.contains(where: { $0.type == .date }) { return .date }
            if entities.contains(where: { $0.type == .person }) { return .text }
        }

        // Default based on step operation
        switch step.operation {
        case .navigateTo: return .url
        case .openDocument, .saveAsFile: return .filepath
        case .launchApp, .switchApp: return .appName
        case .search: return .text
        default: return .text
        }
    }

    /// Generate a human-readable parameter description.
    private static func describeParameter(name: String, step: AbstractStep) -> String {
        switch name {
        case "input_text": return "Text to enter in \(step.target.role)"
        case "destination": return "Where to navigate"
        case "document_name", "document": return "Document to open"
        case "filename": return "Name to save as"
        case "app": return "Application to use"
        case "destination_path": return "Where to move the file"
        default: return "Value for \(name)"
        }
    }

    // MARK: - Step 6: Naming

    /// Generate a concise name for the workflow.
    private static func generateName(journal: WorkflowJournal, steps: [AbstractStep]) -> String {
        // Use the journal's task description if meaningful
        if !journal.taskDescription.isEmpty
            && journal.taskDescription.count < 60
            && journal.taskDescription != "Unknown" {
            return journal.taskDescription
        }

        // Build from the dominant app and primary actions
        let primaryApp = journal.apps.first ?? "Unknown"
        let actionVerbs = steps.prefix(3).map { $0.operation.rawValue.replacingOccurrences(of: "_", with: " ") }

        if actionVerbs.count == 1 {
            return "\(actionVerbs[0].capitalized) in \(primaryApp)"
        }

        let keywords = NLPipeline.extractKeywords(from: journal.topicTerms.joined(separator: " "), limit: 3)
        if !keywords.isEmpty {
            return "\(keywords.joined(separator: " ").capitalized) workflow in \(primaryApp)"
        }

        return "Workflow in \(primaryApp) (\(steps.count) steps)"
    }

    /// Generate a human-readable description.
    private static func generateDescription(journal: WorkflowJournal, steps: [AbstractStep]) -> String {
        let apps = journal.apps.prefix(3).joined(separator: ", ")
        let stepCount = steps.count
        let duration = journal.durationFormatted

        var desc = "\(stepCount)-step workflow"
        if journal.apps.count > 1 {
            desc += " across \(apps)"
        } else {
            desc += " in \(journal.apps.first ?? "Unknown")"
        }
        desc += " (\(duration))"

        // Add first 2-3 action descriptions
        let preview = steps.prefix(3).map { $0.description }.joined(separator: " → ")
        if !preview.isEmpty {
            desc += ": \(preview)"
            if steps.count > 3 { desc += " → ..." }
        }

        return desc
    }

    // MARK: - Step 7: Applicability

    private static func buildApplicability(journal: WorkflowJournal) -> ApplicabilityCondition {
        ApplicabilityCondition(
            requiredApps: journal.apps,
            primaryApp: journal.apps.first ?? "Unknown",
            category: classifyCategory(journal: journal),
            keywords: Array(journal.topicTerms.prefix(10))
        )
    }

    // MARK: - Step 8: Category Classification

    private static func classifyCategory(journal: WorkflowJournal) -> String {
        let text = journal.topicTerms.joined(separator: " ")
        let primaryApp = journal.apps.first ?? ""
        return TopicClassifier.classify(text: text, appName: primaryApp).rawValue
    }

    // MARK: - Step 9: Confidence Scoring

    /// Score confidence in the generalization (0–1).
    /// Higher when: more entries, higher entry confidence, consistent app usage,
    /// clear topic keywords.
    private static func scoreConfidence(
        journal: WorkflowJournal,
        steps: [AbstractStep],
        filtered: [JournalEntry]
    ) -> Double {
        var score = 0.5  // Base

        // More entries = more confidence (up to +0.2)
        let entryBonus = min(0.2, Double(filtered.count) / 50.0)
        score += entryBonus

        // Higher average entry confidence = more confidence (up to +0.15)
        let avgConfidence = filtered.map(\.confidence).reduce(0, +) / Double(max(filtered.count, 1))
        score += avgConfidence * 0.15

        // Fewer apps = more focused workflow = higher confidence (+0.1)
        if journal.apps.count <= 2 {
            score += 0.1
        }

        // Has topic keywords = better understanding (+0.05)
        if journal.topicTerms.count >= 3 {
            score += 0.05
        }

        return min(1.0, score)
    }
}
