import Foundation

struct CommandEntry: Codable, Identifiable {
    let id: UUID
    let command: String
    let result: String
    let timestamp: Date

    init(command: String, result: String) {
        self.id = UUID()
        self.command = command
        self.result = result
        self.timestamp = Date()
    }
}

class CommandHistory: ObservableObject {
    static let shared = CommandHistory()

    @Published var entries: [CommandEntry] = []

    private let storageKey = "command_history"
    private let maxEntries = 100

    private init() {
        load()
    }

    func add(command: String, result: String) {
        let entry = CommandEntry(command: command, result: result)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Get the most recent command matching a prefix.
    func suggest(prefix: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        return entries.first { $0.command.lowercased().hasPrefix(prefix.lowercased()) }?.command
    }

    /// Get the previous command relative to the current index in history navigation.
    func previous(from index: Int) -> (command: String, index: Int)? {
        let nextIndex = index + 1
        guard nextIndex < entries.count else { return nil }
        return (entries[nextIndex].command, nextIndex)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CommandEntry].self, from: data) else {
            return
        }
        entries = decoded
    }
}
