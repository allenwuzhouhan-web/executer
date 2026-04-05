import Foundation

/// Scales a single-instance workflow to operate over a collection of items.
///
/// Phase 11 of the Workflow Recorder ("The Amplifier").
/// "Do that for all 50 files" — identifies the iteration variable,
/// enumerates items, executes the workflow N times with per-item
/// error isolation and progress tracking.
actor BatchOrchestrator {
    static let shared = BatchOrchestrator()

    // MARK: - Batch Execution

    /// Execute a workflow over a batch of items.
    func executeBatch(
        workflow: GeneralizedWorkflow,
        iterationParam: String,
        items: [String],
        fixedParams: [String: String] = [:],
        approvalPolicy: BatchApprovalPolicy = .approveFirstThenAuto,
        onProgress: (@Sendable (BatchProgress) -> Void)? = nil
    ) async -> BatchReport {
        let startTime = Date()
        var results: [BatchItemResult] = []
        var approvedForAll = false

        let bindings = await ParameterBindingEngine.shared.createBatchBindings(
            workflow: workflow,
            iterationParam: iterationParam,
            items: items,
            fixedParams: fixedParams
        )

        for (i, binding) in bindings.enumerated() {
            // Check approval
            if !approvedForAll {
                let shouldProceed: Bool
                switch approvalPolicy {
                case .approveAll:
                    approvedForAll = true
                    shouldProceed = true
                case .approveFirstThenAuto:
                    if i == 0 {
                        shouldProceed = await ApprovalGateway.shared.requestApproval(
                            description: "Execute '\(workflow.name)' on \(items.count) items? First item: \(binding.itemValue)"
                        )
                        if shouldProceed { approvedForAll = true }
                    } else {
                        shouldProceed = true
                    }
                case .approveEach:
                    shouldProceed = await ApprovalGateway.shared.requestApproval(
                        description: "Execute '\(workflow.name)' on: \(binding.itemValue)? (\(i + 1)/\(items.count))"
                    )
                case .approveEveryN(let n):
                    if i % n == 0 {
                        shouldProceed = await ApprovalGateway.shared.requestApproval(
                            description: "Continue '\(workflow.name)'? Items \(i + 1)-\(min(i + n, items.count)) of \(items.count)"
                        )
                        if shouldProceed { approvedForAll = false }  // Will ask again at next N
                    } else {
                        shouldProceed = true
                    }
                }

                if !shouldProceed {
                    // User cancelled
                    let report = buildReport(
                        workflow: workflow, items: items, results: results,
                        startTime: startTime, status: .cancelled
                    )
                    onProgress?(BatchProgress(
                        currentIndex: i, totalItems: items.count,
                        currentItem: binding.itemValue, status: .cancelled
                    ))
                    return report
                }
            }

            // Report progress
            onProgress?(BatchProgress(
                currentIndex: i, totalItems: items.count,
                currentItem: binding.itemValue, status: .executing
            ))

            // Execute workflow for this item
            let replayResult = await AdaptiveReplayEngine.shared.replay(
                workflow: workflow,
                parameters: binding.parameters
            )

            let itemResult: BatchItemResult
            if replayResult.status == .completed {
                itemResult = BatchItemResult(
                    item: binding.itemValue, index: i,
                    status: .success, error: nil
                )
            } else {
                // Per-item error isolation — continue with next item
                itemResult = BatchItemResult(
                    item: binding.itemValue, index: i,
                    status: .failed, error: replayResult.error
                )

                // Try self-healing if available
                if let lastFailed = replayResult.stepResults.last,
                   case .failed(let reason) = lastFailed.status,
                   replayResult.stepsCompleted < workflow.steps.count {
                    let step = workflow.steps[replayResult.stepsCompleted]
                    let healResult = await SelfHealingEngine.shared.heal(
                        failedStep: step, error: reason,
                        workflow: workflow, stepIndex: replayResult.stepsCompleted
                    )
                    if healResult.status == .recovered {
                        // Retry the workflow for this item after healing
                        let retryResult = await AdaptiveReplayEngine.shared.replay(
                            workflow: workflow, parameters: binding.parameters
                        )
                        if retryResult.status == .completed {
                            results.append(BatchItemResult(
                                item: binding.itemValue, index: i,
                                status: .recoveredAndSucceeded, error: nil
                            ))
                            continue
                        }
                    }
                }
            }

            results.append(itemResult)

            // Check circuit breaker — too many consecutive failures
            let recentFailures = results.suffix(3).filter { $0.status == .failed }.count
            if recentFailures >= 3 {
                print("[BatchOrchestrator] Circuit breaker: 3 consecutive failures")
                let report = buildReport(
                    workflow: workflow, items: items, results: results,
                    startTime: startTime, status: .circuitBroken
                )
                return report
            }

            onProgress?(BatchProgress(
                currentIndex: i, totalItems: items.count,
                currentItem: binding.itemValue,
                status: itemResult.status == .success ? .itemCompleted : .itemFailed(itemResult.error ?? "Unknown")
            ))
        }

        return buildReport(
            workflow: workflow, items: items, results: results,
            startTime: startTime, status: .completed
        )
    }

    // MARK: - Item Enumeration

    /// Enumerate items from various sources.
    static func enumerateItems(source: ItemSource) -> [String] {
        switch source {
        case .fileGlob(let pattern):
            return enumerateFileGlob(pattern)
        case .list(let items):
            return items
        case .directory(let path):
            return enumerateDirectory(path)
        }
    }

    private static func enumerateFileGlob(_ pattern: String) -> [String] {
        let expanded = (pattern as NSString).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        let filePattern = (expanded as NSString).lastPathComponent

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        return contents.filter { filename in
            // Simple wildcard matching
            if filePattern.contains("*") {
                let regex = filePattern
                    .replacingOccurrences(of: ".", with: "\\.")
                    .replacingOccurrences(of: "*", with: ".*")
                return filename.range(of: regex, options: .regularExpression) != nil
            }
            return filename == filePattern
        }.map { "\(dir)/\($0)" }
    }

    private static func enumerateDirectory(_ path: String) -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: expanded) else { return [] }
        return contents.map { "\(expanded)/\($0)" }
    }

    // MARK: - Report Building

    private func buildReport(
        workflow: GeneralizedWorkflow,
        items: [String],
        results: [BatchItemResult],
        startTime: Date,
        status: BatchStatus
    ) -> BatchReport {
        let successes = results.filter { $0.status == .success || $0.status == .recoveredAndSucceeded }.count
        let failures = results.filter { $0.status == .failed }.count

        return BatchReport(
            workflowName: workflow.name,
            totalItems: items.count,
            processed: results.count,
            succeeded: successes,
            failed: failures,
            skipped: items.count - results.count,
            duration: Date().timeIntervalSince(startTime),
            status: status,
            itemResults: results
        )
    }
}

// MARK: - Models

enum BatchApprovalPolicy: Sendable {
    case approveAll                  // Approve upfront for all items
    case approveFirstThenAuto        // Approve first item, then auto-approve rest
    case approveEach                 // Approve each item individually
    case approveEveryN(Int)          // Approve every Nth item
}

enum ItemSource: Sendable {
    case fileGlob(String)            // "~/Documents/*.pdf"
    case list([String])              // Explicit list
    case directory(String)           // All files in directory
}

struct BatchProgress: Sendable {
    let currentIndex: Int
    let totalItems: Int
    let currentItem: String
    let status: Status

    enum Status: Sendable {
        case executing, itemCompleted, itemFailed(String), cancelled
    }

    var percentComplete: Double {
        guard totalItems > 0 else { return 0 }
        return Double(currentIndex + 1) / Double(totalItems) * 100.0
    }

    var estimatedTimeRemaining: String? {
        // Simple linear estimation — could be improved
        guard currentIndex > 0, totalItems > currentIndex else { return nil }
        return "\(totalItems - currentIndex - 1) items remaining"
    }
}

struct BatchItemResult: Sendable {
    let item: String
    let index: Int
    let status: Status
    let error: String?

    enum Status: String, Sendable {
        case success, failed, skipped, recoveredAndSucceeded
    }
}

struct BatchReport: Sendable {
    let workflowName: String
    let totalItems: Int
    let processed: Int
    let succeeded: Int
    let failed: Int
    let skipped: Int
    let duration: TimeInterval
    let status: BatchStatus
    let itemResults: [BatchItemResult]

    var summary: String {
        let durStr = duration < 60 ? "\(Int(duration))s" : "\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s"
        return "\(workflowName): \(succeeded)/\(totalItems) succeeded, \(failed) failed, \(skipped) skipped (\(durStr))"
    }
}

enum BatchStatus: String, Sendable {
    case completed           // All items processed
    case cancelled           // User cancelled
    case circuitBroken       // Too many consecutive failures
}
