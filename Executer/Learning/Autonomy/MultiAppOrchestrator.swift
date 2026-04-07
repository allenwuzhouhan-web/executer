import Foundation
import AppKit

/// Orchestrates workflows spanning multiple applications.
///
/// Phase 9 of the Workflow Recorder ("The Conductor").
/// Replaces the basic MultiAppCoordinator (just timing delays) with real
/// orchestration: app lifecycle management, intelligent data passing,
/// window routing, and readiness detection.
actor MultiAppOrchestrator {
    static let shared = MultiAppOrchestrator()

    // MARK: - Configuration

    private let appLaunchTimeout: TimeInterval = 10
    private let readinessPollingInterval: TimeInterval = 0.3
    private let readinessStabilityCount = 3  // AX tree must be stable for 3 consecutive polls
    private let maxReadinessWait: TimeInterval = 15

    // MARK: - App Segment Execution

    /// Execute a sequence of AppSegments — the multi-app workflow plan.
    func execute(
        segments: [AppSegment],
        dataContext: DataContext = DataContext(),
        onProgress: (@Sendable (SegmentProgress) -> Void)? = nil
    ) async -> OrchestrationResult {
        var context = dataContext
        var completedSegments = 0

        for (i, segment) in segments.enumerated() {
            onProgress?(SegmentProgress(
                segmentIndex: i,
                totalSegments: segments.count,
                app: segment.appName,
                status: .starting
            ))

            // 1. Switch to the target app
            let launched = await switchToApp(segment.appName)
            if !launched {
                return OrchestrationResult(
                    status: .failed,
                    completedSegments: completedSegments,
                    totalSegments: segments.count,
                    error: "Failed to switch to \(segment.appName)"
                )
            }

            // 2. Wait for app readiness
            let ready = await waitForReadiness(app: segment.appName, windowPattern: segment.expectedWindowPattern)
            if !ready {
                return OrchestrationResult(
                    status: .failed,
                    completedSegments: completedSegments,
                    totalSegments: segments.count,
                    error: "\(segment.appName) did not become ready within \(Int(maxReadinessWait))s"
                )
            }

            // 3. Route to correct window if specified
            if let windowPattern = segment.expectedWindowPattern {
                await routeToWindow(pattern: windowPattern, app: segment.appName)
            }

            // 4. Inject input data if the segment expects it
            if let inputBinding = segment.dataInput {
                let injected = await injectData(binding: inputBinding, context: context)
                if !injected {
                    return OrchestrationResult(
                        status: .failed,
                        completedSegments: completedSegments,
                        totalSegments: segments.count,
                        error: "Failed to inject data into \(segment.appName)"
                    )
                }
            }

            // 5. Execute the segment's steps via AdaptiveReplayEngine
            for step in segment.steps {
                let success = await executeSegmentStep(step, app: segment.appName, context: &context)
                if !success {
                    return OrchestrationResult(
                        status: .failed,
                        completedSegments: completedSegments,
                        totalSegments: segments.count,
                        error: "Step failed in \(segment.appName): \(step.description)"
                    )
                }
            }

            // 6. Extract output data if the segment produces it
            if let outputBinding = segment.dataOutput {
                await extractData(binding: outputBinding, context: &context)
            }

            completedSegments += 1
            onProgress?(SegmentProgress(
                segmentIndex: i,
                totalSegments: segments.count,
                app: segment.appName,
                status: .completed
            ))
        }

        return OrchestrationResult(
            status: .completed,
            completedSegments: completedSegments,
            totalSegments: segments.count,
            error: nil
        )
    }

    // MARK: - App Switching

    private func switchToApp(_ appName: String) async -> Bool {
        // First check if already frontmost
        if let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName,
           frontApp.lowercased() == appName.lowercased() {
            return true
        }

        // Try to activate via running apps
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: { $0.localizedName?.lowercased() == appName.lowercased() }) {
            app.activate()
            // Wait for activation
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if app.isActive { return true }
            }
        }

        // App not running — try to launch
        do {
            let argsData = try JSONSerialization.data(withJSONObject: ["app_name": appName])
            let args = String(data: argsData, encoding: .utf8) ?? "{}"
            _ = try await ToolRegistry.shared.execute(toolName: "launch_app", arguments: args)
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s for launch
            return UIStateVerifier.verifyFrontmostApp(appName)
        } catch {
            return false
        }
    }

    // MARK: - Readiness Detection

    /// Wait for an app to be truly ready — UI tree must be stable (not still loading).
    private func waitForReadiness(app appName: String, windowPattern: String?) async -> Bool {
        let deadline = Date().addingTimeInterval(maxReadinessWait)
        var stableCount = 0
        var lastElementCount = -1

        while Date() < deadline {
            // Check if the app is frontmost
            guard UIStateVerifier.verifyFrontmostApp(appName) else {
                try? await Task.sleep(nanoseconds: UInt64(readinessPollingInterval * 1_000_000_000))
                continue
            }

            // Read the AX tree and check element count stability
            guard let frontApp = NSWorkspace.shared.frontmostApplication else { continue }
            let texts = ScreenReader.readVisibleText(pid: frontApp.processIdentifier)
            let elementCount = texts.count

            if elementCount == lastElementCount && elementCount > 3 {
                stableCount += 1
                if stableCount >= readinessStabilityCount {
                    return true  // UI is stable
                }
            } else {
                stableCount = 0
            }
            lastElementCount = elementCount

            try? await Task.sleep(nanoseconds: UInt64(readinessPollingInterval * 1_000_000_000))
        }

        // Timed out but app is at least running
        return UIStateVerifier.verifyFrontmostApp(appName)
    }

    // MARK: - Window Routing

    /// Focus the correct window when an app has multiple windows.
    private func routeToWindow(pattern: String, app: String) async {
        // Try to find a window matching the pattern via AX
        if let _ = AdaptiveExecutor.findElement(description: pattern) {
            // Element found — the right window is likely visible
            return
        }
        // Could try Cmd+` cycling or Window menu, but for now just proceed
    }

    // MARK: - Data Bridge

    /// Inject data into the current app context.
    private func injectData(binding: DataBinding, context: DataContext) async -> Bool {
        switch binding.method {
        case .clipboard:
            // Put the data on clipboard, then paste
            guard let value = context.values[binding.key] else { return false }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            try? await Task.sleep(nanoseconds: 200_000_000)
            do {
                _ = try await ToolRegistry.shared.execute(toolName: "press_key", arguments: "{\"key\": \"command+v\"}")
                return true
            } catch { return false }

        case .file:
            // Data was written to a temp file — the key holds the file path
            // The app should open it
            guard let path = context.values[binding.key] else { return false }
            do {
                let argsData = try JSONSerialization.data(withJSONObject: ["file_path": path])
                let args = String(data: argsData, encoding: .utf8) ?? "{}"
                _ = try await ToolRegistry.shared.execute(toolName: "open_file", arguments: args)
                return true
            } catch { return false }

        case .directType:
            // Type the data directly into the focused element
            guard let value = context.values[binding.key] else { return false }
            do {
                let argsData = try JSONSerialization.data(withJSONObject: ["text": value])
                let args = String(data: argsData, encoding: .utf8) ?? "{}"
                _ = try await ToolRegistry.shared.execute(toolName: "type_text", arguments: args)
                return true
            } catch { return false }
        }
    }

    /// Extract data from the current app context.
    private func extractData(binding: DataBinding, context: inout DataContext) async {
        switch binding.method {
        case .clipboard:
            // Copy, then read clipboard
            do {
                _ = try await ToolRegistry.shared.execute(toolName: "press_key", arguments: "{\"key\": \"command+c\"}")
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let content = NSPasteboard.general.string(forType: .string) {
                    context.values[binding.key] = content
                }
            } catch {}

        case .file:
            // Data already in a file — store path
            // The caller should set this up
            break

        case .directType:
            // Read from the focused element's value
            if let text = AdaptiveExecutor.findElement(description: binding.key) {
                context.values[binding.key] = text
            }
        }
    }

    // MARK: - Step Execution

    private func executeSegmentStep(_ step: AbstractStep, app: String, context: inout DataContext) async -> Bool {
        // Resolve any parameter bindings from the data context
        var params: [String: String] = [:]
        for (key, template) in step.parameterBindings {
            if template.hasPrefix("{{") && template.hasSuffix("}}") {
                let paramName = String(template.dropFirst(2).dropLast(2))
                params[key] = context.values[paramName] ?? template
            } else {
                params[key] = template
            }
        }

        let replayContext = ReplayContext(
            workflow: GeneralizedWorkflow(
                name: "segment", description: "", steps: [step],
                applicability: ApplicabilityCondition(requiredApps: [app], primaryApp: app, category: "", keywords: [])
            ),
            parameters: params
        )

        let result = await AdaptiveReplayEngine.shared.replay(
            workflow: replayContext.workflow,
            parameters: params
        )
        return result.status == .completed
    }
}

// MARK: - Models

/// A segment of a multi-app workflow — actions within a single app.
struct AppSegment: Codable, Sendable {
    let appName: String
    let expectedWindowPattern: String?     // Window title to look for
    let steps: [AbstractStep]              // Actions to perform in this app
    let dataInput: DataBinding?            // Data to inject before steps
    let dataOutput: DataBinding?           // Data to extract after steps
}

/// Describes how data flows between app segments.
struct DataBinding: Codable, Sendable {
    let key: String                        // Name of the data value
    let method: TransferMethod

    enum TransferMethod: String, Codable, Sendable {
        case clipboard                     // Via system clipboard
        case file                          // Via temp file
        case directType                    // Type directly into element
    }
}

/// Mutable context carrying data between segments.
struct DataContext: Sendable {
    var values: [String: String] = [:]     // Key → value pairs flowing between apps
}

struct SegmentProgress: Sendable {
    let segmentIndex: Int
    let totalSegments: Int
    let app: String
    let status: Status
    enum Status: Sendable { case starting, executing, completed, failed(String) }
}

struct OrchestrationResult: Sendable {
    let status: OrchestrationStatus
    let completedSegments: Int
    let totalSegments: Int
    let error: String?
}

enum OrchestrationStatus: String, Sendable {
    case completed, failed, cancelled
}
