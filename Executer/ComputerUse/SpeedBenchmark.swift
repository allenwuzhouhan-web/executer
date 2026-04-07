import Foundation

/// Measures per-action latency for optimization and debugging.
class SpeedBenchmark {
    static let shared = SpeedBenchmark()

    struct ActionTiming {
        let tool: String
        let durationMs: Int
        let timestamp: Date
    }

    private var timings: [ActionTiming] = []
    private let lock = NSLock()

    /// Record a tool execution timing.
    func record(tool: String, durationMs: Int) {
        lock.lock()
        defer { lock.unlock() }
        timings.append(ActionTiming(tool: tool, durationMs: durationMs, timestamp: Date()))
        // Keep only last 200 entries
        if timings.count > 200 {
            timings.removeFirst(timings.count - 200)
        }
    }

    /// Get average latency for a specific tool.
    func averageLatency(for tool: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let relevant = timings.filter { $0.tool == tool }
        guard !relevant.isEmpty else { return nil }
        let total = relevant.reduce(0) { $0 + $1.durationMs }
        return total / relevant.count
    }

    /// Get total time for all recorded actions.
    func totalTime() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return timings.reduce(0) { $0 + $1.durationMs }
    }

    /// Human-readable report of timing statistics.
    func report() -> String {
        lock.lock()
        let snapshot = timings
        lock.unlock()

        guard !snapshot.isEmpty else { return "No timings recorded." }

        var byTool: [String: [Int]] = [:]
        for t in snapshot {
            byTool[t.tool, default: []].append(t.durationMs)
        }

        var lines: [String] = ["Speed Benchmark Report"]
        lines.append("Total actions: \(snapshot.count)")
        lines.append("Total time: \(totalTime())ms")
        lines.append("")

        for (tool, durations) in byTool.sorted(by: { $0.value.count > $1.value.count }) {
            let avg = durations.reduce(0, +) / durations.count
            let max = durations.max() ?? 0
            let min = durations.min() ?? 0
            lines.append("  \(tool): avg=\(avg)ms min=\(min)ms max=\(max)ms (x\(durations.count))")
        }

        return lines.joined(separator: "\n")
    }

    /// Clear all recorded timings.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        timings.removeAll()
    }
}
