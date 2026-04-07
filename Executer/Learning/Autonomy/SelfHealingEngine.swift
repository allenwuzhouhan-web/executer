import Foundation

/// Self-healing error recovery for workflow replay.
///
/// Phase 10 of the Workflow Recorder ("The Phoenix").
/// When a step fails: diagnose → classify → select recovery → attempt → record.
/// Replaces the static ErrorRecoveryStrategy lookup table with contextual
/// diagnosis that learns from past recoveries.
actor SelfHealingEngine {
    static let shared = SelfHealingEngine()

    /// Maximum recovery attempts per step before giving up.
    private let maxRecoveryAttempts = 3

    /// Persistent memory of past failure→recovery mappings.
    private var recoveryMemory: [String: RecoveryRecord] = [:]

    /// Load recovery memory from UserDefaults on init.
    init() {
        if let data = UserDefaults.standard.data(forKey: "com.executer.recoveryMemory"),
           let decoded = try? JSONDecoder().decode([String: RecoveryRecord].self, from: data) {
            recoveryMemory = decoded
        }
    }

    // MARK: - Healing Pipeline

    /// Attempt to recover from a failed step.
    /// Returns the recovery result and whether the step can proceed.
    func heal(
        failedStep: AbstractStep,
        error: String,
        workflow: GeneralizedWorkflow,
        stepIndex: Int
    ) async -> HealingResult {
        // 1. Diagnose the failure
        let diagnosis = await diagnose(step: failedStep, error: error)

        // 2. Check recovery memory for a known fix
        let memoryKey = makeMemoryKey(step: failedStep, failureType: diagnosis.failureType)
        if let record = recoveryMemory[memoryKey], record.successCount > 0 {
            let success = await attemptRecovery(record.strategy, step: failedStep, diagnosis: diagnosis)
            if success {
                updateMemory(key: memoryKey, strategy: record.strategy, succeeded: true)
                return HealingResult(status: .recovered, strategy: record.strategy, diagnosis: diagnosis, attempts: 1)
            }
        }

        // 3. Try recovery strategies in order of likelihood
        let strategies = selectStrategies(for: diagnosis)

        for (attempt, strategy) in strategies.enumerated() {
            if attempt >= maxRecoveryAttempts { break }

            let success = await attemptRecovery(strategy, step: failedStep, diagnosis: diagnosis)
            if success {
                updateMemory(key: memoryKey, strategy: strategy, succeeded: true)
                return HealingResult(status: .recovered, strategy: strategy, diagnosis: diagnosis, attempts: attempt + 1)
            }
        }

        // 4. All strategies failed
        return HealingResult(status: .failed, strategy: .abort, diagnosis: diagnosis, attempts: maxRecoveryAttempts)
    }

    // MARK: - Diagnosis

    /// Diagnose why a step failed by examining the error and current screen state.
    private func diagnose(step: AbstractStep, error: String) async -> FailureDiagnosis {
        let errorLower = error.lowercased()

        // Check if correct app is frontmost
        let correctApp = UIStateVerifier.verifyFrontmostApp(step.appContext)

        // Classify failure type
        let failureType: FailureType

        if !correctApp {
            failureType = .wrongApp
        } else if errorLower.contains("not found") || errorLower.contains("no element") || errorLower.contains("could not find") {
            failureType = .elementNotFound
        } else if errorLower.contains("dialog") || errorLower.contains("alert") || errorLower.contains("popup") || errorLower.contains("sheet") {
            failureType = .dialogBlocking
        } else if errorLower.contains("timeout") || errorLower.contains("timed out") {
            failureType = .timeout
        } else if errorLower.contains("crash") || errorLower.contains("terminated") {
            failureType = .appCrashed
        } else if errorLower.contains("permission") || errorLower.contains("denied") || errorLower.contains("access") {
            failureType = .permissionDenied
        } else {
            failureType = .stateMismatch
        }

        return FailureDiagnosis(
            failureType: failureType,
            error: error,
            stepOperation: step.operation,
            expectedApp: step.appContext,
            isCorrectApp: correctApp,
            severity: failureType.severity
        )
    }

    // MARK: - Strategy Selection

    /// Select recovery strategies ordered by likelihood of success for this failure type.
    private func selectStrategies(for diagnosis: FailureDiagnosis) -> [RecoveryStrategy] {
        switch diagnosis.failureType {
        case .elementNotFound:
            return [.retryWithDelay, .scrollAndRetry, .dismissDialogAndRetry, .skip]
        case .wrongApp:
            return [.switchToCorrectApp, .retryWithDelay]
        case .dialogBlocking:
            return [.dismissDialogAndRetry, .pressEscapeAndRetry, .retryWithDelay]
        case .timeout:
            return [.waitAndRetry, .retryWithDelay]
        case .appCrashed:
            return [.relaunchAppAndRetry, .abort]
        case .permissionDenied:
            return [.skip, .abort]
        case .stateMismatch:
            return [.retryWithDelay, .scrollAndRetry, .skip]
        }
    }

    // MARK: - Recovery Execution

    /// Attempt a single recovery strategy.
    private func attemptRecovery(
        _ strategy: RecoveryStrategy,
        step: AbstractStep,
        diagnosis: FailureDiagnosis
    ) async -> Bool {
        print("[SelfHealing] Attempting \(strategy.rawValue) for \(diagnosis.failureType.rawValue)")

        switch strategy {
        case .retryWithDelay:
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s delay
            return await retryStep(step)

        case .waitAndRetry:
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s delay
            return await retryStep(step)

        case .switchToCorrectApp:
            do {
                let argsData = try JSONSerialization.data(withJSONObject: ["app_name": step.appContext])
                let args = String(data: argsData, encoding: .utf8) ?? "{}"
                _ = try await ToolRegistry.shared.execute(toolName: "launch_app", arguments: args)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return UIStateVerifier.verifyFrontmostApp(step.appContext)
            } catch { return false }

        case .dismissDialogAndRetry:
            // Try clicking common dismiss buttons
            for label in ["OK", "Cancel", "Close", "Done", "Dismiss", "Don't Save"] {
                if let _ = AdaptiveExecutor.findElement(description: label) {
                    do {
                        let args = "{\"element_description\": \"\(label)\"}"
                        _ = try await ToolRegistry.shared.execute(toolName: "click_element", arguments: args)
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        return true
                    } catch { continue }
                }
            }
            return false

        case .pressEscapeAndRetry:
            do {
                _ = try await ToolRegistry.shared.execute(toolName: "press_key", arguments: "{\"key\": \"escape\"}")
                try? await Task.sleep(nanoseconds: 500_000_000)
                return await retryStep(step)
            } catch { return false }

        case .scrollAndRetry:
            do {
                _ = try await ToolRegistry.shared.execute(toolName: "press_key", arguments: "{\"key\": \"pagedown\"}")
                try? await Task.sleep(nanoseconds: 500_000_000)
                return await retryStep(step)
            } catch { return false }

        case .relaunchAppAndRetry:
            do {
                let argsData = try JSONSerialization.data(withJSONObject: ["app_name": step.appContext])
                let args = String(data: argsData, encoding: .utf8) ?? "{}"
                _ = try await ToolRegistry.shared.execute(toolName: "launch_app", arguments: args)
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s for relaunch
                return UIStateVerifier.verifyFrontmostApp(step.appContext)
            } catch { return false }

        case .skip:
            return true  // "Success" by skipping

        case .abort:
            return false
        }
    }

    /// Retry the failed step using the replay engine.
    private func retryStep(_ step: AbstractStep) async -> Bool {
        let miniWorkflow = GeneralizedWorkflow(
            name: "retry", description: step.description, steps: [step],
            applicability: ApplicabilityCondition(requiredApps: [step.appContext], primaryApp: step.appContext, category: "", keywords: [])
        )
        let result = await AdaptiveReplayEngine.shared.replay(workflow: miniWorkflow)
        return result.status == .completed
    }

    // MARK: - Recovery Memory

    private func makeMemoryKey(step: AbstractStep, failureType: FailureType) -> String {
        "\(step.operation.rawValue):\(step.appContext):\(failureType.rawValue)"
    }

    private func updateMemory(key: String, strategy: RecoveryStrategy, succeeded: Bool) {
        var record = recoveryMemory[key] ?? RecoveryRecord(strategy: strategy, successCount: 0, failCount: 0)
        if succeeded {
            record.successCount += 1
            record.strategy = strategy
        } else {
            record.failCount += 1
        }
        record.lastUsed = Date()
        recoveryMemory[key] = record
        persistMemory()
    }

    private func persistMemory() {
        if let data = try? JSONEncoder().encode(recoveryMemory) {
            UserDefaults.standard.set(data, forKey: "com.executer.recoveryMemory")
        }
    }

    // MARK: - Types

    struct RecoveryRecord: Codable, Sendable {
        var strategy: RecoveryStrategy
        var successCount: Int
        var failCount: Int
        var lastUsed: Date = Date()
    }
}

// MARK: - Failure Types

enum FailureType: String, Codable, Sendable {
    case elementNotFound     // Target UI element doesn't exist on screen
    case wrongApp            // Different app is frontmost than expected
    case dialogBlocking      // A dialog/alert is covering the target
    case timeout             // Operation timed out
    case appCrashed          // The target app crashed or quit
    case permissionDenied    // macOS permission blocked the action
    case stateMismatch       // Screen state doesn't match expectations

    var severity: FailureSeverity {
        switch self {
        case .elementNotFound, .dialogBlocking: return .moderate
        case .wrongApp, .timeout, .stateMismatch: return .moderate
        case .appCrashed, .permissionDenied: return .critical
        }
    }
}

enum FailureSeverity: String, Codable, Sendable {
    case minor, moderate, critical
}

struct FailureDiagnosis: Sendable {
    let failureType: FailureType
    let error: String
    let stepOperation: AbstractOperation
    let expectedApp: String
    let isCorrectApp: Bool
    let severity: FailureSeverity
}

enum RecoveryStrategy: String, Codable, Sendable {
    case retryWithDelay
    case waitAndRetry
    case switchToCorrectApp
    case dismissDialogAndRetry
    case pressEscapeAndRetry
    case scrollAndRetry
    case relaunchAppAndRetry
    case skip
    case abort
}

struct HealingResult: Sendable {
    let status: HealingStatus
    let strategy: RecoveryStrategy
    let diagnosis: FailureDiagnosis
    let attempts: Int
}

enum HealingStatus: String, Sendable {
    case recovered   // Self-healing succeeded
    case failed      // All recovery strategies exhausted
    case skipped     // Step was skipped
}
