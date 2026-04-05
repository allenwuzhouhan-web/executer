import Foundation
import Cocoa

// MARK: - Step 8: Task Scheduler

struct ScheduledTask: Codable {
    let id: String
    let command: String
    let scheduledDate: Date
    let repeatIntervalMinutes: Int?
    let label: String?
    var completed: Bool
}

class TaskScheduler {
    static let shared = TaskScheduler()

    private(set) var tasks: [ScheduledTask] = []
    private var timers: [String: Timer] = [:]

    private let storageURL: URL = {
        let appSupport = URL.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scheduled_tasks.json")
    }()

    private init() {
        loadFromDisk()
    }

    func resumePendingTasks() {
        let pending = tasks.filter { !$0.completed }
        print("[TaskScheduler] Resuming \(pending.count) pending tasks")
        for task in pending {
            scheduleTimer(for: task)
        }
    }

    func addTask(command: String, scheduledDate: Date, repeatIntervalMinutes: Int? = nil, label: String? = nil) -> ScheduledTask {
        let task = ScheduledTask(
            id: UUID().uuidString,
            command: command,
            scheduledDate: scheduledDate,
            repeatIntervalMinutes: repeatIntervalMinutes,
            label: label,
            completed: false
        )
        tasks.append(task)
        saveToDisk()
        scheduleTimer(for: task)
        print("[TaskScheduler] Scheduled task '\(label ?? command.prefix(30).description)' for \(scheduledDate)")
        return task
    }

    func pendingTasks() -> [ScheduledTask] {
        return tasks.filter { !$0.completed }.sorted { $0.scheduledDate < $1.scheduledDate }
    }

    func cancelTask(id: String) -> Bool {
        timers[id]?.invalidate()
        timers.removeValue(forKey: id)
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].completed = true
            saveToDisk()
            return true
        }
        return false
    }

    // MARK: - Timer Management

    private func scheduleTimer(for task: ScheduledTask) {
        timers[task.id]?.invalidate()

        let interval = task.scheduledDate.timeIntervalSinceNow
        if interval <= 0 {
            // Task is overdue — fire immediately
            fireTask(task)
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fireTask(task)
        }
        timers[task.id] = timer
    }

    private func fireTask(_ task: ScheduledTask) {
        print("[TaskScheduler] Firing task: \(task.label ?? task.command.prefix(30).description)")

        // Submit through AppState on the main thread
        DispatchQueue.main.async {
            // Access AppDelegate to get appState
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                delegate.appState.showInputBar()
                delegate.appState.submitCommand(task.command)
            }
        }

        // Mark as completed
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx].completed = true

            // Handle repeating tasks
            if let repeatMinutes = task.repeatIntervalMinutes, repeatMinutes > 0 {
                let nextDate = Date().addingTimeInterval(Double(repeatMinutes) * 60)
                let newTask = ScheduledTask(
                    id: UUID().uuidString,
                    command: task.command,
                    scheduledDate: nextDate,
                    repeatIntervalMinutes: repeatMinutes,
                    label: task.label,
                    completed: false
                )
                tasks.append(newTask)
                scheduleTimer(for: newTask)
            }
        }

        timers.removeValue(forKey: task.id)
        saveToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            tasks = try decoder.decode([ScheduledTask].self, from: data)
            // Clean up old completed tasks (older than 7 days)
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            tasks = tasks.filter { !$0.completed || $0.scheduledDate > cutoff }
            print("[TaskScheduler] Loaded \(tasks.count) tasks from disk")
        } catch {
            print("[TaskScheduler] Failed to load: \(error)")
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(tasks)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[TaskScheduler] Failed to save: \(error)")
        }
    }
}
