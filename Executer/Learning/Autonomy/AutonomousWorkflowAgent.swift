import Foundation
import AppKit

/// The capstone: fully autonomous workflow discovery and execution.
///
/// Phase 20 of the Workflow Recorder ("The Sovereign").
/// Executer stops waiting for "do that again" and starts doing things
/// the user hasn't asked for. Observes patterns → recognizes as automatable →
/// creates workflow → offers to take over (or just does it at high trust).
///
/// Five graduated autonomy levels:
///   1. Observe only — silent
///   2. Suggest via notification — "I noticed you're doing X, want me to help?"
///   3. Preview before applying — show what would happen, get approval
///   4. Execute with supervision — run with live progress, user can stop
///   5. Fully autonomous — run silently, post-hoc report
///
/// Composes EVERY previous phase into a closed-loop agent.
actor AutonomousWorkflowAgent {
    static let shared = AutonomousWorkflowAgent()

    // MARK: - Configuration

    private var isEnabled = false
    private var globalAutonomyLevel: AutonomyLevel = .suggest
    private var perCategoryLevels: [String: AutonomyLevel] = [:]

    /// Minimum confidence to act at each autonomy level.
    private let confidenceThresholds: [AutonomyLevel: Double] = [
        .observeOnly: 0.0,
        .suggest: 0.4,
        .preview: 0.6,
        .supervise: 0.75,
        .autonomous: 0.9,
    ]

    /// Cooldown between autonomous actions on the same pattern.
    private let actionCooldown: TimeInterval = 300  // 5 minutes
    private var lastActionTime: [String: Date] = [:]

    // MARK: - State

    private var monitoringTask: Task<Void, Never>?
    private var recentOpportunities: [AutomationOpportunity] = []
    private var executionHistory: [AutonomousExecution] = []

    // MARK: - Lifecycle

    /// Start the autonomous agent. Begins monitoring the observation stream for opportunities.
    func start() {
        guard !isEnabled else { return }
        isEnabled = true

        // Load preferences
        loadPreferences()

        print("[Sovereign] Autonomous workflow agent started at level: \(globalAutonomyLevel.rawValue)")
    }

    /// Stop the autonomous agent.
    func stop() {
        isEnabled = false
        monitoringTask?.cancel()
        monitoringTask = nil
        print("[Sovereign] Stopped")
    }

    // MARK: - Opportunity Detection

    /// Process an observation event and check for automation opportunities.
    /// Called by the ContinuousPerceptionDaemon consumer pipeline.
    func processEvent(_ event: ObservationEvent) async {
        guard isEnabled else { return }

        // 1. Check for active repetition (user doing same thing right now)
        await ProactiveSuggestionEngine.shared.feedEvent(event)

        // 2. Periodically check for opportunities (not on every event — too expensive)
        // Rate-limit to once per 30 seconds
        let now = Date()
        if let lastCheck = lastActionTime["__opportunity_check"],
           now.timeIntervalSince(lastCheck) < 30 {
            return
        }
        lastActionTime["__opportunity_check"] = now

        // 3. Detect opportunities
        let opportunities = await detectOpportunities()

        for opportunity in opportunities {
            // 4. Assess risk
            let risk = assessRisk(opportunity)

            // 5. Determine autonomy level for this opportunity
            let level = effectiveLevel(for: opportunity, risk: risk)

            // 6. Check confidence threshold
            guard opportunity.confidence >= (confidenceThresholds[level] ?? 1.0) else { continue }

            // 7. Check cooldown
            let cooldownKey = opportunity.patternKey
            if let lastTime = lastActionTime[cooldownKey],
               now.timeIntervalSince(lastTime) < actionCooldown {
                continue
            }

            // 8. Act based on autonomy level
            await act(on: opportunity, level: level, risk: risk)
            lastActionTime[cooldownKey] = now
        }
    }

    // MARK: - Opportunity Detection Pipeline

    private func detectOpportunities() async -> [AutomationOpportunity] {
        var opportunities: [AutomationOpportunity] = []

        // Source 1: Proactive suggestions (temporal, calendar, repetition)
        let suggestions = await ProactiveSuggestionEngine.shared.generateSuggestions()
        for suggestion in suggestions {
            opportunities.append(AutomationOpportunity(
                type: .proactiveSuggestion,
                workflow: suggestion.workflow,
                confidence: suggestion.confidence,
                reason: suggestion.reason,
                patternKey: suggestion.typeKey
            ))
        }

        // Source 2: Known workflows matching current context
        let currentApp = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        }
        if !currentApp.isEmpty {
            let appWorkflows = await WorkflowRepository.shared.searchByApp(currentApp, limit: 3)
            for wf in appWorkflows where wf.timesUsed > 2 {
                opportunities.append(AutomationOpportunity(
                    type: .frequentWorkflow,
                    workflow: wf,
                    confidence: min(Double(wf.timesUsed) / 10.0, 0.8),
                    reason: "Used \(wf.timesUsed) times in \(currentApp)",
                    patternKey: "freq:\(wf.id)"
                ))
            }
        }

        return opportunities
    }

    // MARK: - Risk Assessment

    private func assessRisk(_ opportunity: AutomationOpportunity) -> RiskAssessment {
        let workflow = opportunity.workflow
        var riskScore = 0.0
        var concerns: [String] = []

        // Check for destructive operations
        let destructiveOps: Set<AbstractOperation> = [.deleteFile, .quitApp, .closeDocument]
        let hasDestructive = workflow.steps.contains { destructiveOps.contains($0.operation) }
        if hasDestructive {
            riskScore += 0.4
            concerns.append("Contains destructive operations")
        }

        // Check for multi-app (higher risk of unintended side effects)
        if workflow.applicability.requiredApps.count > 2 {
            riskScore += 0.2
            concerns.append("Spans \(workflow.applicability.requiredApps.count) apps")
        }

        // Check for text input (might enter wrong data)
        let hasTextInput = workflow.steps.contains { $0.operation == .fillField || $0.operation == .editText }
        if hasTextInput {
            riskScore += 0.15
            concerns.append("Involves text input")
        }

        // Proven workflows are less risky
        if workflow.timesUsed > 5 {
            riskScore -= 0.1
        }

        let level: RiskAssessment.RiskLevel
        if riskScore >= 0.5 { level = .high }
        else if riskScore >= 0.3 { level = .moderate }
        else { level = .low }

        return RiskAssessment(level: level, score: min(max(riskScore, 0), 1), concerns: concerns)
    }

    // MARK: - Autonomy Level Selection

    /// Determine the effective autonomy level for an opportunity.
    private func effectiveLevel(for opportunity: AutomationOpportunity, risk: RiskAssessment) -> AutonomyLevel {
        // Start with per-category level, fall back to global
        let baseLevel = perCategoryLevels[opportunity.workflow.category] ?? globalAutonomyLevel

        // Downgrade if risk is high
        if risk.level == .high {
            return min(baseLevel, .preview)  // Never auto-execute high-risk
        }
        if risk.level == .moderate {
            return min(baseLevel, .supervise)  // At most supervised execution
        }

        return baseLevel
    }

    // MARK: - Action Execution

    private func act(on opportunity: AutomationOpportunity, level: AutonomyLevel, risk: RiskAssessment) async {
        print("[Sovereign] Acting on opportunity: \(opportunity.reason) at level \(level.rawValue)")

        switch level {
        case .observeOnly:
            // Log only
            break

        case .suggest:
            // Post a notification
            NotificationCenter.default.post(
                name: .autonomousWorkflowSuggestion,
                object: nil,
                userInfo: [
                    "workflow": opportunity.workflow,
                    "reason": opportunity.reason,
                    "confidence": opportunity.confidence,
                ]
            )

        case .preview:
            // Generate a preview of what would happen
            let preview = generatePreview(opportunity.workflow)
            NotificationCenter.default.post(
                name: .autonomousWorkflowPreview,
                object: nil,
                userInfo: [
                    "workflow": opportunity.workflow,
                    "preview": preview,
                    "reason": opportunity.reason,
                ]
            )

        case .supervise:
            // Execute with supervision UI
            let result = await AdaptiveReplayEngine.shared.replay(
                workflow: opportunity.workflow,
                parameters: [:],
                onProgress: { progress in
                    NotificationCenter.default.post(
                        name: .autonomousWorkflowProgress,
                        object: nil,
                        userInfo: ["progress": progress]
                    )
                }
            )
            recordExecution(opportunity: opportunity, result: result, level: level)

        case .autonomous:
            // Execute silently, report after
            let result = await AdaptiveReplayEngine.shared.replay(
                workflow: opportunity.workflow,
                parameters: [:]
            )
            recordExecution(opportunity: opportunity, result: result, level: level)

            // Post-hoc report
            let report = PostHocReporter.generateReport(
                workflow: opportunity.workflow,
                result: result,
                reason: opportunity.reason
            )
            NotificationCenter.default.post(
                name: .autonomousWorkflowCompleted,
                object: nil,
                userInfo: ["report": report]
            )
        }
    }

    // MARK: - Preview Generation

    private func generatePreview(_ workflow: GeneralizedWorkflow) -> String {
        var lines = ["If I run '\(workflow.name)', here's what will happen:"]
        for (i, step) in workflow.steps.prefix(10).enumerated() {
            lines.append("  \(i + 1). \(step.description)")
        }
        if workflow.steps.count > 10 {
            lines.append("  ... and \(workflow.steps.count - 10) more steps")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Execution Recording

    private func recordExecution(opportunity: AutomationOpportunity, result: ReplayResult, level: AutonomyLevel) {
        executionHistory.append(AutonomousExecution(
            workflowId: opportunity.workflow.id,
            workflowName: opportunity.workflow.name,
            level: level,
            result: result.status,
            reason: opportunity.reason,
            timestamp: Date()
        ))

        // Keep last 100
        if executionHistory.count > 100 {
            executionHistory.removeFirst(executionHistory.count - 100)
        }
    }

    // MARK: - Preferences

    /// Set the global autonomy level.
    func setGlobalLevel(_ level: AutonomyLevel) {
        globalAutonomyLevel = level
        persistPreferences()
        print("[Sovereign] Global autonomy level set to: \(level.rawValue)")
    }

    /// Set autonomy level for a specific workflow category.
    func setCategoryLevel(_ category: String, level: AutonomyLevel) {
        perCategoryLevels[category] = level
        persistPreferences()
    }

    private func loadPreferences() {
        if let rawValue = UserDefaults.standard.string(forKey: "com.executer.sovereign.globalLevel"),
           let level = AutonomyLevel(rawValue: rawValue) {
            globalAutonomyLevel = level
        }
        if let data = UserDefaults.standard.data(forKey: "com.executer.sovereign.categoryLevels"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            perCategoryLevels = decoded.compactMapValues { AutonomyLevel(rawValue: $0) }
        }
    }

    private func persistPreferences() {
        UserDefaults.standard.set(globalAutonomyLevel.rawValue, forKey: "com.executer.sovereign.globalLevel")
        let encoded = perCategoryLevels.mapValues(\.rawValue)
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: "com.executer.sovereign.categoryLevels")
        }
    }

    // MARK: - Status

    func statusDescription() -> String {
        var lines = ["Autonomous Workflow Agent:"]
        lines.append("  Status: \(isEnabled ? "active" : "inactive")")
        lines.append("  Global level: \(globalAutonomyLevel.rawValue)")
        if !perCategoryLevels.isEmpty {
            lines.append("  Per-category: \(perCategoryLevels.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ", "))")
        }
        lines.append("  Autonomous executions: \(executionHistory.count)")
        let successful = executionHistory.filter { $0.result == .completed }.count
        if !executionHistory.isEmpty {
            lines.append("  Success rate: \(Int(Double(successful) / Double(executionHistory.count) * 100))%")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Autonomy Levels

enum AutonomyLevel: String, Codable, Sendable, Comparable {
    case observeOnly = "observe"
    case suggest = "suggest"
    case preview = "preview"
    case supervise = "supervise"
    case autonomous = "autonomous"

    private var rank: Int {
        switch self {
        case .observeOnly: return 0
        case .suggest: return 1
        case .preview: return 2
        case .supervise: return 3
        case .autonomous: return 4
        }
    }

    static func < (lhs: AutonomyLevel, rhs: AutonomyLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - Opportunity Model

struct AutomationOpportunity: Sendable {
    let type: OpportunityType
    let workflow: GeneralizedWorkflow
    let confidence: Double
    let reason: String
    let patternKey: String    // For cooldown tracking

    enum OpportunityType: String, Sendable {
        case proactiveSuggestion    // From ProactiveSuggestionEngine
        case frequentWorkflow       // Known workflow for current app
        case activeRepetition       // User doing same thing repeatedly right now
    }
}

// MARK: - Risk Assessment

struct RiskAssessment: Sendable {
    let level: RiskLevel
    let score: Double          // 0–1
    let concerns: [String]

    enum RiskLevel: String, Sendable {
        case low, moderate, high
    }
}

// MARK: - Execution Record

struct AutonomousExecution: Sendable {
    let workflowId: UUID
    let workflowName: String
    let level: AutonomyLevel
    let result: ReplayStatus
    let reason: String
    let timestamp: Date
}

// MARK: - Post-Hoc Reporter

/// Generates reports after autonomous execution.
enum PostHocReporter {
    static func generateReport(
        workflow: GeneralizedWorkflow,
        result: ReplayResult,
        reason: String
    ) -> String {
        var lines: [String] = []

        let status = result.status == .completed ? "completed successfully" : "failed"
        lines.append("Autonomous execution \(status): **\(workflow.name)**")
        lines.append("Reason: \(reason)")
        lines.append("Steps: \(result.stepsCompleted)/\(result.stepsTotal)")

        if let error = result.error {
            lines.append("Error: \(error)")
        }

        // What was done
        if result.stepsCompleted > 0 {
            lines.append("Actions taken:")
            for (i, step) in workflow.steps.prefix(result.stepsCompleted).enumerated() {
                lines.append("  \(i + 1). \(step.description)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let autonomousWorkflowSuggestion = Notification.Name("com.executer.autonomous.suggestion")
    static let autonomousWorkflowPreview = Notification.Name("com.executer.autonomous.preview")
    static let autonomousWorkflowProgress = Notification.Name("com.executer.autonomous.progress")
    static let autonomousWorkflowCompleted = Notification.Name("com.executer.autonomous.completed")
}
