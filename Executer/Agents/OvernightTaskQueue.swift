import Foundation

/// Persistent priority queue for overnight tasks.
/// Survives agent expiry, app restarts, and individual task failures.
/// Stored at ~/Library/Application Support/Executer/overnight_queue.json.
class OvernightTaskQueue {
    static let shared = OvernightTaskQueue()

    private var tasks: [OvernightTask] = []
    private let lock = NSLock()

    private static var storageURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
            .appendingPathComponent("overnight_queue.json")
    }

    private init() { loadFromDisk() }

    // MARK: - Queue Operations

    func enqueue(_ task: OvernightTask) {
        lock.lock()
        // Dedup by title + source
        if !tasks.contains(where: { $0.title == task.title && $0.source == task.source && $0.state == .pending }) {
            tasks.append(task)
            tasks.sort { $0.priority > $1.priority }
        }
        lock.unlock()
        saveToDisk()
    }

    func enqueueAll(_ newTasks: [OvernightTask]) {
        lock.lock()
        for task in newTasks {
            if !tasks.contains(where: { $0.title == task.title && $0.source == task.source && $0.state == .pending }) {
                tasks.append(task)
            }
        }
        tasks.sort { $0.priority > $1.priority }
        lock.unlock()
        saveToDisk()
    }

    func dequeueNext() -> OvernightTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.first(where: { $0.state == .pending })
    }

    func markExecuting(id: UUID) {
        lock.lock()
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].state = .executing
            tasks[idx].startedAt = Date()
        }
        lock.unlock()
        saveToDisk()
    }

    func markCompleted(id: UUID, result: OvernightTask.TaskResult) {
        lock.lock()
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].state = .completed
            tasks[idx].completedAt = Date()
            tasks[idx].result = result
        }
        lock.unlock()
        saveToDisk()
    }

    func markFailed(id: UUID, reason: String) {
        lock.lock()
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].retryCount += 1
            if tasks[idx].retryCount >= tasks[idx].maxRetries {
                tasks[idx].state = .failed
            } else {
                tasks[idx].state = .pending  // Will retry
            }
            tasks[idx].result = OvernightTask.TaskResult(
                summary: "Failed: \(reason)", confidence: 0, outputPath: nil,
                toolsUsed: [], durationSeconds: 0
            )
        }
        lock.unlock()
        saveToDisk()
    }

    func markSkipped(id: UUID, reason: String) {
        lock.lock()
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].state = .skipped
            tasks[idx].result = OvernightTask.TaskResult(
                summary: "Skipped: \(reason)", confidence: 0, outputPath: nil,
                toolsUsed: [], durationSeconds: 0
            )
        }
        lock.unlock()
        saveToDisk()
    }

    func markNeedsReview(id: UUID, reason: String) {
        lock.lock()
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].state = .needsReview
        }
        lock.unlock()
        saveToDisk()
    }

    // MARK: - Queries

    func pendingTasks() -> [OvernightTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.filter { $0.state == .pending }
    }

    func completedTasks() -> [OvernightTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.filter { $0.state == .completed }
    }

    func failedTasks() -> [OvernightTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.filter { $0.state == .failed }
    }

    func needsReviewTasks() -> [OvernightTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.filter { $0.state == .needsReview }
    }

    func allTasks() -> [OvernightTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks
    }

    var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    // MARK: - Undo

    func undoAction(taskId: UUID, actionIndex: Int) async -> Bool {
        lock.lock()
        guard let task = tasks.first(where: { $0.id == taskId }),
              actionIndex < task.reversibleActions.count else {
            lock.unlock()
            return false
        }
        let action = task.reversibleActions[actionIndex]
        lock.unlock()

        // Check undo window
        guard Date() < action.expiresAt else { return false }

        do {
            _ = try await ToolRegistry.shared.execute(
                toolName: action.toolName,
                arguments: action.rollbackArguments
            )

            lock.lock()
            if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[idx].state = .undone
            }
            lock.unlock()
            saveToDisk()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Cleanup

    func pruneOlderThan(days: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        lock.lock()
        tasks.removeAll { $0.discoveredAt < cutoff && $0.state != .pending && $0.state != .executing }
        lock.unlock()
        saveToDisk()
    }

    func clearAll() {
        lock.lock()
        tasks.removeAll()
        lock.unlock()
        saveToDisk()
    }

    // MARK: - Persistence

    func saveToDisk() {
        lock.lock()
        let snapshot = tasks
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: Self.storageURL, options: .atomic)
        }
    }

    func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([OvernightTask].self, from: data) {
            lock.lock()
            tasks = loaded
            // Reset any tasks that were "executing" when app quit
            for i in tasks.indices where tasks[i].state == .executing {
                tasks[i].state = .pending
            }
            lock.unlock()
        }
    }
}

// MARK: - OvernightTask Model

struct OvernightTask: Codable, Identifiable {
    let id: UUID
    let source: TaskSource
    let title: String
    let description: String
    var actionPlan: String
    var state: TaskState
    let priority: Double
    let discoveredAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var result: TaskResult?
    let estimatedMinutes: Int
    var retryCount: Int
    let maxRetries: Int
    var reversibleActions: [ReversibleAction]

    init(
        source: TaskSource, title: String, description: String,
        actionPlan: String = "", priority: Double = 0.5,
        estimatedMinutes: Int = 5, maxRetries: Int = 1
    ) {
        self.id = UUID()
        self.source = source
        self.title = title
        self.description = description
        self.actionPlan = actionPlan
        self.state = .pending
        self.priority = priority
        self.discoveredAt = Date()
        self.startedAt = nil
        self.completedAt = nil
        self.result = nil
        self.estimatedMinutes = estimatedMinutes
        self.retryCount = 0
        self.maxRetries = maxRetries
        self.reversibleActions = []
    }

    enum TaskSource: String, Codable {
        case email, wechat, calendar, reminder, goalStack
        case fileChange, webMonitor, workflow, manual
    }

    enum TaskState: String, Codable {
        case pending, executing, completed, failed
        case skipped, needsReview, undone
    }

    struct TaskResult: Codable {
        let summary: String
        let confidence: Double
        let outputPath: String?
        let toolsUsed: [String]
        let durationSeconds: Int
    }

    struct ReversibleAction: Codable {
        let description: String
        let toolName: String
        let rollbackArguments: String
        let expiresAt: Date
    }
}
