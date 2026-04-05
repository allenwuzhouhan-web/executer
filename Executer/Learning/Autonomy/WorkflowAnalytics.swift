import Foundation

/// Comprehensive workflow execution analytics, optimization, and ROI measurement.
///
/// Phase 19 of the Workflow Recorder ("The Refiner").
/// Tracks per-step metrics, identifies bottlenecks, auto-optimizes workflows,
/// and measures cumulative time saved.
actor WorkflowAnalytics {
    static let shared = WorkflowAnalytics()

    /// In-memory execution log (also persisted to UserDefaults).
    private var executionLog: [WorkflowExecution] = []
    private let maxLogEntries = 500
    private let storageKey = "com.executer.workflowAnalytics"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([WorkflowExecution].self, from: data) {
            executionLog = decoded
        }
    }

    // MARK: - Recording

    /// Record a workflow execution with per-step timing.
    func recordExecution(_ execution: WorkflowExecution) {
        executionLog.append(execution)
        if executionLog.count > maxLogEntries {
            executionLog.removeFirst(executionLog.count - maxLogEntries)
        }
        persistLog()
    }

    /// Record from a ReplayResult.
    func recordFromReplay(
        workflowId: UUID,
        workflowName: String,
        result: ReplayResult,
        stepDurations: [UUID: TimeInterval] = [:]
    ) {
        let execution = WorkflowExecution(
            workflowId: workflowId,
            workflowName: workflowName,
            status: result.status == .completed ? .success : .failed,
            totalDuration: stepDurations.values.reduce(0, +),
            stepMetrics: result.stepResults.map { stepResult in
                StepMetric(
                    stepId: stepResult.stepId,
                    duration: stepDurations[stepResult.stepId] ?? 0,
                    status: stepResult.status,
                    retries: stepResult.attempts - 1
                )
            },
            timestamp: Date()
        )
        Task { await recordExecution(execution) }
    }

    // MARK: - Analytics Queries

    /// Get execution history for a specific workflow.
    func history(forWorkflow workflowId: UUID, limit: Int = 20) -> [WorkflowExecution] {
        Array(executionLog.filter { $0.workflowId == workflowId }.suffix(limit))
    }

    /// Get success rate for a workflow.
    func successRate(forWorkflow workflowId: UUID) -> Double {
        let executions = executionLog.filter { $0.workflowId == workflowId }
        guard !executions.isEmpty else { return 0 }
        let successes = executions.filter { $0.status == .success }.count
        return Double(successes) / Double(executions.count)
    }

    /// Get average execution time for a workflow.
    func averageDuration(forWorkflow workflowId: UUID) -> TimeInterval {
        let executions = executionLog.filter { $0.workflowId == workflowId && $0.status == .success }
        guard !executions.isEmpty else { return 0 }
        return executions.map(\.totalDuration).reduce(0, +) / Double(executions.count)
    }

    /// Identify bottleneck steps (slowest or most error-prone).
    func bottlenecks(forWorkflow workflowId: UUID) -> [BottleneckInfo] {
        let executions = executionLog.filter { $0.workflowId == workflowId }
        guard !executions.isEmpty else { return [] }

        // Aggregate per-step metrics
        var stepTotals: [UUID: (totalDuration: TimeInterval, failures: Int, executions: Int)] = [:]

        for execution in executions {
            for metric in execution.stepMetrics {
                var current = stepTotals[metric.stepId] ?? (0, 0, 0)
                current.totalDuration += metric.duration
                current.executions += 1
                if case .failed = metric.status { current.failures += 1 }
                stepTotals[metric.stepId] = current
            }
        }

        return stepTotals.map { (stepId, totals) in
            let avgDuration = totals.executions > 0 ? totals.totalDuration / Double(totals.executions) : 0
            let failureRate = totals.executions > 0 ? Double(totals.failures) / Double(totals.executions) : 0

            return BottleneckInfo(
                stepId: stepId,
                averageDuration: avgDuration,
                failureRate: failureRate,
                totalExecutions: totals.executions,
                isBottleneck: avgDuration > 5.0 || failureRate > 0.3  // >5s or >30% failure
            )
        }
        .filter(\.isBottleneck)
        .sorted { $0.failureRate > $1.failureRate }
    }

    // MARK: - ROI Calculator

    /// Estimate time saved by a workflow.
    /// Compares original journal duration (manual) to average automated duration.
    func calculateROI(
        workflowId: UUID,
        originalManualDuration: TimeInterval
    ) -> ROIReport {
        let executions = executionLog.filter { $0.workflowId == workflowId && $0.status == .success }
        let totalExecutions = executions.count
        let avgAutomatedDuration = averageDuration(forWorkflow: workflowId)

        let timeSavedPerExecution = max(0, originalManualDuration - avgAutomatedDuration)
        let totalTimeSaved = timeSavedPerExecution * Double(totalExecutions)

        return ROIReport(
            workflowId: workflowId,
            totalExecutions: totalExecutions,
            averageManualDuration: originalManualDuration,
            averageAutomatedDuration: avgAutomatedDuration,
            timeSavedPerExecution: timeSavedPerExecution,
            totalTimeSaved: totalTimeSaved,
            successRate: successRate(forWorkflow: workflowId),
            speedupFactor: avgAutomatedDuration > 0 ? originalManualDuration / avgAutomatedDuration : 1.0
        )
    }

    /// Calculate total time saved across ALL workflows.
    func totalTimeSaved() -> TimeInterval {
        // Group by workflow, estimate savings
        let workflowIds = Set(executionLog.map(\.workflowId))
        var total: TimeInterval = 0

        for id in workflowIds {
            let executions = executionLog.filter { $0.workflowId == id && $0.status == .success }
            let avgDuration = executions.isEmpty ? 0 : executions.map(\.totalDuration).reduce(0, +) / Double(executions.count)

            // Estimate manual duration as 5x automated (conservative)
            let estimatedManual = avgDuration * 5.0
            let savedPerExecution = max(0, estimatedManual - avgDuration)
            total += savedPerExecution * Double(executions.count)
        }

        return total
    }

    // MARK: - Optimization Suggestions

    /// Generate optimization suggestions for a workflow.
    func optimizationSuggestions(
        workflow: GeneralizedWorkflow
    ) -> [OptimizationSuggestion] {
        var suggestions: [OptimizationSuggestion] = []

        let bottleneckSteps = bottlenecks(forWorkflow: workflow.id)

        // Suggestion 1: High-failure steps
        for bottleneck in bottleneckSteps where bottleneck.failureRate > 0.3 {
            suggestions.append(OptimizationSuggestion(
                type: .removeUnreliableStep,
                stepId: bottleneck.stepId,
                description: "Step fails \(Int(bottleneck.failureRate * 100))% of the time — consider removing or replacing it",
                impact: .high
            ))
        }

        // Suggestion 2: Parallelization potential
        let analysis = ParallelScheduler.analyzeParallelism(workflow: workflow)
        if analysis.isWorthParallelizing {
            suggestions.append(OptimizationSuggestion(
                type: .parallelize,
                stepId: nil,
                description: "Can parallelize \(analysis.maxParallelBranches) branches for ~\(String(format: "%.1f", analysis.theoreticalSpeedup))x speedup",
                impact: .high
            ))
        }

        // Suggestion 3: Slow steps
        for bottleneck in bottleneckSteps where bottleneck.averageDuration > 10 {
            suggestions.append(OptimizationSuggestion(
                type: .speedUpSlowStep,
                stepId: bottleneck.stepId,
                description: "Step averages \(Int(bottleneck.averageDuration))s — may benefit from keyboard shortcuts",
                impact: .medium
            ))
        }

        // Suggestion 4: Redundant app switches
        var consecutiveAppSteps: [(app: String, count: Int)] = []
        var currentApp = ""
        var currentCount = 0
        for step in workflow.steps {
            if step.appContext == currentApp {
                currentCount += 1
            } else {
                if currentCount > 0 { consecutiveAppSteps.append((currentApp, currentCount)) }
                currentApp = step.appContext
                currentCount = 1
            }
        }
        if currentCount > 0 { consecutiveAppSteps.append((currentApp, currentCount)) }

        // If app switches back and forth, suggest reordering
        let appSwitchCount = consecutiveAppSteps.count
        if appSwitchCount > workflow.steps.count / 2 && appSwitchCount > 4 {
            suggestions.append(OptimizationSuggestion(
                type: .reduceAppSwitches,
                stepId: nil,
                description: "\(appSwitchCount) app switches — consider grouping same-app steps together",
                impact: .medium
            ))
        }

        return suggestions.sorted { $0.impact.rank > $1.impact.rank }
    }

    // MARK: - Impact Summary

    /// Generate a human-readable impact summary.
    func impactSummary() -> String {
        let total = totalTimeSaved()
        let workflowCount = Set(executionLog.map(\.workflowId)).count
        let execCount = executionLog.count
        let successCount = executionLog.filter { $0.status == .success }.count

        let hours = Int(total / 3600)
        let minutes = Int((total.truncatingRemainder(dividingBy: 3600)) / 60)

        var lines: [String] = []
        lines.append("Workflow Analytics Summary:")
        lines.append("  Workflows tracked: \(workflowCount)")
        lines.append("  Total executions: \(execCount) (\(successCount) successful)")
        if hours > 0 {
            lines.append("  Estimated time saved: \(hours)h \(minutes)m")
        } else {
            lines.append("  Estimated time saved: \(minutes)m")
        }

        // Top performing workflows
        let byWorkflow = Dictionary(grouping: executionLog, by: \.workflowId)
        let topWorkflows = byWorkflow
            .map { (id, execs) -> (String, Int) in
                let name = execs.first?.workflowName ?? "Unknown"
                return (name, execs.filter { $0.status == .success }.count)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)

        if !topWorkflows.isEmpty {
            lines.append("  Most used:")
            for (name, count) in topWorkflows {
                lines.append("    \(name): \(count) executions")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func persistLog() {
        if let data = try? JSONEncoder().encode(executionLog) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Models

struct WorkflowExecution: Codable, Sendable {
    let workflowId: UUID
    let workflowName: String
    let status: ExecutionOutcome
    let totalDuration: TimeInterval
    let stepMetrics: [StepMetric]
    let timestamp: Date

    enum ExecutionOutcome: String, Codable, Sendable {
        case success, failed, cancelled
    }
}

struct StepMetric: Codable, Sendable {
    let stepId: UUID
    let duration: TimeInterval
    let succeeded: Bool
    let errorMessage: String?
    let retries: Int

    init(stepId: UUID, duration: TimeInterval, status: StepStatus, retries: Int) {
        self.stepId = stepId
        self.duration = duration
        if case .failed(let msg) = status {
            self.succeeded = false
            self.errorMessage = msg
        } else {
            if case .skipped = status { self.succeeded = false } else { self.succeeded = true }
            self.errorMessage = nil
        }
        self.retries = retries
    }

    var status: StepStatus {
        if let error = errorMessage { return .failed(error) }
        return succeeded ? .succeeded : .skipped
    }
}

struct BottleneckInfo: Sendable {
    let stepId: UUID
    let averageDuration: TimeInterval
    let failureRate: Double
    let totalExecutions: Int
    let isBottleneck: Bool
}

struct ROIReport: Sendable {
    let workflowId: UUID
    let totalExecutions: Int
    let averageManualDuration: TimeInterval
    let averageAutomatedDuration: TimeInterval
    let timeSavedPerExecution: TimeInterval
    let totalTimeSaved: TimeInterval
    let successRate: Double
    let speedupFactor: Double

    var summary: String {
        let hours = Int(totalTimeSaved / 3600)
        let minutes = Int((totalTimeSaved.truncatingRemainder(dividingBy: 3600)) / 60)
        let timeStr = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return "\(totalExecutions) runs, \(String(format: "%.1f", speedupFactor))x faster, \(timeStr) saved total (\(String(format: "%.0f", successRate * 100))% success rate)"
    }
}

struct OptimizationSuggestion: Sendable {
    let type: SuggestionType
    let stepId: UUID?
    let description: String
    let impact: Impact

    enum SuggestionType: String, Sendable {
        case removeUnreliableStep
        case parallelize
        case speedUpSlowStep
        case reduceAppSwitches
        case cacheFrequentData
    }

    enum Impact: String, Sendable {
        case high, medium, low

        var rank: Int {
            switch self { case .high: return 3; case .medium: return 2; case .low: return 1 }
        }
    }
}
