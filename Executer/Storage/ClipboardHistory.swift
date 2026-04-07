import Cocoa

// MARK: - Step 2: Clipboard History Manager

struct ClipboardEntry: Codable {
    let id: String
    let text: String
    let timestamp: Date
    let sourceApp: String?
}

class ClipboardHistoryManager {
    static let shared = ClipboardHistoryManager()

    private var entries: [ClipboardEntry] = []
    private let entriesLock = NSLock()
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var lastSaveTime: Date = .distantPast
    private let maxEntries = 500

    private let storageURL: URL = {
        let appSupport = URL.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard_history.json")
    }()

    private init() {
        loadFromDisk()
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func startMonitoring() {
        print("[ClipboardHistory] Starting clipboard monitoring")
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        // Skip if identical to last entry
        entriesLock.lock()
        let lastText = entries.first?.text
        entriesLock.unlock()
        if lastText == text { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        let entry = ClipboardEntry(
            id: UUID().uuidString,
            text: text,
            timestamp: Date(),
            sourceApp: sourceApp
        )

        entriesLock.lock()
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        entriesLock.unlock()

        guard Date().timeIntervalSince(lastSaveTime) > 10 else { return }
        saveToDisk()
        lastSaveTime = Date()
        print("[ClipboardHistory] Captured entry from \(sourceApp ?? "unknown") (\(text.prefix(50))...)")
    }

    // MARK: - Query

    func getHistory(limit: Int = 20, minutesAgo: Int? = nil) -> [ClipboardEntry] {
        entriesLock.lock()
        let snapshot = entries
        entriesLock.unlock()
        var filtered = snapshot
        if let minutes = minutesAgo {
            let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
            filtered = filtered.filter { $0.timestamp >= cutoff }
        }
        return Array(filtered.prefix(limit))
    }

    func search(query: String, limit: Int = 10) -> [ClipboardEntry] {
        let lower = query.lowercased()
        entriesLock.lock()
        let snapshot = entries
        entriesLock.unlock()
        let matches = snapshot.filter { $0.text.lowercased().contains(lower) }
        return Array(matches.prefix(limit))
    }

    func clearAll() {
        entriesLock.lock()
        entries.removeAll()
        entriesLock.unlock()
        saveToDisk()
        print("[ClipboardHistory] History cleared")
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([ClipboardEntry].self, from: data)
            entriesLock.lock()
            entries = loaded
            entriesLock.unlock()
            print("[ClipboardHistory] Loaded \(loaded.count) entries from disk")
        } catch {
            print("[ClipboardHistory] Failed to load: \(error)")
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            entriesLock.lock()
            let snapshot = entries
            entriesLock.unlock()
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[ClipboardHistory] Failed to save: \(error)")
        }
    }
}
