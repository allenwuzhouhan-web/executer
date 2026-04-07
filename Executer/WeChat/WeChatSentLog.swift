import Foundation

/// Audit log for all messages sent via WeChat.
/// Stored at ~/Library/Application Support/Executer/wechat_sent_log.json
class WeChatSentLog {
    static let shared = WeChatSentLog()

    struct Entry: Codable {
        let timestamp: Date
        let recipient: String
        let text: String
        let platform: String // "wechat" or "imessage"
    }

    private var entries: [Entry] = []

    private let storageURL: URL = {
        let appSupport = URL.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wechat_sent_log.json")
    }()

    private init() {
        load()
    }

    func log(recipient: String, text: String, platform: String = "wechat") {
        let entry = Entry(
            timestamp: Date(),
            recipient: recipient,
            text: text,
            platform: platform
        )
        entries.append(entry)
        save()
    }

    /// Get entries for today (or a specific date)
    func todayEntries() -> [Entry] {
        let calendar = Calendar.current
        return entries.filter { calendar.isDateInToday($0.timestamp) }
    }

    /// Get all entries within the last N days
    func recentEntries(days: Int = 7) -> [Entry] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return entries.filter { $0.timestamp >= cutoff }
    }

    /// Format entries for display
    func formatEntries(_ entries: [Entry]) -> String {
        if entries.isEmpty { return "No messages sent." }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] → \(entry.recipient): \(entry.text) (\(entry.platform))"
        }.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try SecureStorage.writeEncrypted(data, to: storageURL)
        } catch {
            print("[WeChatLog] Failed to save: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try SecureStorage.readEncrypted(from: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([Entry].self, from: data)
        } catch {
            // Try plaintext fallback for first run
            do {
                let plainData = try Data(contentsOf: storageURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                entries = try decoder.decode([Entry].self, from: plainData)
                save()
            } catch {
                print("[WeChatLog] Failed to load: \(error)")
            }
        }
    }
}
