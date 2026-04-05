import Foundation

/// Complete audit trail of autonomous workflow executions.
final class ExecutionLogger {
    static let shared = ExecutionLogger()

    private var log: [ExecutionResult] = []
    private let lock = NSLock()

    private init() { loadLog() }

    func record(_ result: ExecutionResult) {
        lock.lock()
        log.append(result)
        lock.unlock()
        saveLog()
    }

    func recentExecutions(limit: Int = 20) -> [ExecutionResult] {
        lock.lock()
        defer { lock.unlock() }
        return Array(log.suffix(limit))
    }

    func successRate() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard !log.isEmpty else { return 0 }
        return Double(log.filter { $0.status == .completed }.count) / Double(log.count)
    }

    private var fileURL: URL {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
        return dir.appendingPathComponent("execution_log.json")
    }

    private func loadLog() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([ExecutionResult].self, from: data) else { return }
        log = loaded
    }

    private func saveLog() {
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
