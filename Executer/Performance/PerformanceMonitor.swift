import Foundation
import os

/// Instruments-compatible performance monitoring via os_signpost.
final class PerformanceMonitor {
    static let shared = PerformanceMonitor()

    private let log = OSLog(subsystem: "com.executer.performance", category: .pointsOfInterest)
    private let signposter: OSSignposter

    // Aggregate metrics (ring buffer of last 100 samples per category)
    private let metricsQueue = DispatchQueue(label: "com.executer.metrics", qos: .utility)
    private var routingSamples: [Double] = []
    private var toolExecSamples: [Double] = []
    private var llmLatencySamples: [Double] = []
    private var endToEndSamples: [Double] = []
    private let maxSamples = 100

    private init() {
        signposter = OSSignposter(logHandle: log)
    }

    // MARK: - Signpost API

    func beginRouting() -> OSSignpostIntervalState {
        signposter.beginInterval("AgentRouting", id: signposter.makeSignpostID())
    }

    func endRouting(_ state: OSSignpostIntervalState, agentId: String = "general") {
        signposter.endInterval("AgentRouting", state, "\(agentId)")
    }

    func beginToolExec(_ toolName: String) -> OSSignpostIntervalState {
        signposter.beginInterval("ToolExecution", id: signposter.makeSignpostID(), "\(toolName)")
    }

    func endToolExec(_ state: OSSignpostIntervalState) {
        signposter.endInterval("ToolExecution", state)
    }

    func beginLLMCall() -> OSSignpostIntervalState {
        signposter.beginInterval("LLMCall", id: signposter.makeSignpostID())
    }

    func endLLMCall(_ state: OSSignpostIntervalState) {
        signposter.endInterval("LLMCall", state)
    }

    func beginEndToEnd() -> OSSignpostIntervalState {
        signposter.beginInterval("EndToEnd", id: signposter.makeSignpostID())
    }

    func endEndToEnd(_ state: OSSignpostIntervalState) {
        signposter.endInterval("EndToEnd", state)
    }

    // MARK: - Metrics Recording

    func recordRouting(ms: Double) {
        record(&routingSamples, value: ms)
    }

    func recordToolExec(ms: Double) {
        record(&toolExecSamples, value: ms)
    }

    func recordLLMLatency(ms: Double) {
        record(&llmLatencySamples, value: ms)
    }

    func recordEndToEnd(ms: Double) {
        record(&endToEndSamples, value: ms)
    }

    private func record(_ samples: inout [Double], value: Double) {
        metricsQueue.sync {
            samples.append(value)
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
        }
    }

    // MARK: - Aggregates

    var averageRoutingMs: Double { average(routingSamples) }
    var averageToolExecMs: Double { average(toolExecSamples) }
    var averageLLMLatencyMs: Double { average(llmLatencySamples) }
    var averageEndToEndMs: Double { average(endToEndSamples) }

    private func average(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// Human-readable performance summary.
    func summary() -> String {
        let profile = SiliconProfile.shared
        return """
            Silicon: \(profile.chipName) (\(profile.computeTier))
            Cores: \(profile.performanceCoreCount)P + \(profile.efficiencyCoreCount)E
            Memory: \(profile.totalMemoryGB)GB
            Neural Engine: \(profile.hasNeuralEngine ? "Yes" : "No")
            Metal GPU: Family \(profile.metalGPUFamily)

            Avg routing: \(String(format: "%.1f", averageRoutingMs))ms
            Avg tool exec: \(String(format: "%.1f", averageToolExecMs))ms
            Avg LLM latency: \(String(format: "%.1f", averageLLMLatencyMs))ms
            Avg end-to-end: \(String(format: "%.1f", averageEndToEndMs))ms
            """
    }
}
