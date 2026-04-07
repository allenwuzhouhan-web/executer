import Foundation
import Combine

/// Entry representing a single site visited during a browser task.
struct BrowserTrailEntry: Identifiable, Codable {
    let id: UUID
    let url: String
    let title: String
    let summary: String
    let timestamp: Date

    init(id: UUID = UUID(), url: String, title: String, summary: String, timestamp: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.summary = summary
        self.timestamp = timestamp
    }
}

/// Observable store for the most recent browser task's URL trail.
/// Separate from BrowserService (actor) because SwiftUI needs @MainActor + ObservableObject.
/// Persists entries to ~/Library/Application Support/Executer/browser_trails.json.
@MainActor
final class BrowserTrailStore: ObservableObject {
    static let shared = BrowserTrailStore()

    @Published var currentTrail: [BrowserTrailEntry] = []

    private static let maxEntries = 500

    private static var persistenceURL: URL {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("browser_trails.json")
    }

    private var saveCancellable: AnyCancellable?

    private init() {
        loadFromDisk()
        // Auto-save whenever currentTrail changes (including direct assignment from external code)
        saveCancellable = $currentTrail
            .dropFirst() // skip the initial value from loadFromDisk
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveToDisk()
            }
    }

    func append(_ entry: BrowserTrailEntry) {
        currentTrail.append(entry)
    }

    func clear() {
        currentTrail.removeAll()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        let url = Self.persistenceURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let entries = try JSONDecoder().decode([BrowserTrailEntry].self, from: data)
            currentTrail = entries
        } catch {
            print("[BrowserTrailStore] Failed to load trails: \(error)")
        }
    }

    private func saveToDisk() {
        // Prune to max entries, keeping newest
        if currentTrail.count > Self.maxEntries {
            currentTrail = Array(currentTrail.suffix(Self.maxEntries))
        }
        do {
            let data = try JSONEncoder().encode(currentTrail)
            try data.write(to: Self.persistenceURL, options: .atomic)
        } catch {
            print("[BrowserTrailStore] Failed to save trails: \(error)")
        }
    }
}
