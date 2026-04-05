import Foundation

/// Security audit log — in-memory ring buffer + encrypted disk persistence.
actor AuditLog {
    static let shared = AuditLog()

    struct Entry: Codable {
        let date: Date
        let sessionID: String
        let tool: String
        let tierLevel: Int  // ToolRiskTier raw value
        let argPreview: String
        let resultPreview: String

        var tierName: String {
            switch tierLevel {
            case 0: return "safe"
            case 1: return "normal"
            case 2: return "elevated"
            case 3: return "critical"
            default: return "unknown"
            }
        }
    }

    private let maxEntries = 1000
    private var entries: [Entry] = []
    private var currentSegment: [Entry] = []
    private let sessionID = UUID().uuidString

    /// Retention period for encrypted audit segments.
    private let retentionDays = 7

    func log(tool: String, args: String, result: String, tier: ToolRiskTier) {
        let entry = Entry(
            date: Date(),
            sessionID: sessionID,
            tool: tool,
            tierLevel: tier.rawValue,
            argPreview: String(args.prefix(200)),
            resultPreview: String(result.prefix(200))
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // Also buffer for disk persistence
        currentSegment.append(entry)

        // Auto-rotate segment when it reaches capacity
        if currentSegment.count >= maxEntries {
            Task { await rotateSegment() }
        }

        // Print elevated+ to console for visibility
        if tier >= .elevated {
            print("[SECURITY] \(tier) tool: \(tool) — args: \(String(args.prefix(100)))")
        }
    }

    /// Returns recent entries (for diagnostics / security dashboard).
    func recentEntries(count: Int = 50) -> [Entry] {
        Array(entries.suffix(count))
    }

    /// Total entries in current session.
    var entryCount: Int { entries.count }

    // MARK: - Disk Persistence

    private var auditDirectory: URL {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
            .appendingPathComponent("audit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Flush current segment to encrypted file. Called on app quit and segment rotation.
    func persistToDisk() {
        guard !currentSegment.isEmpty else { return }

        do {
            let data = try JSONEncoder().encode(currentSegment)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let filename = "audit_\(formatter.string(from: Date())).enc"
            let fileURL = auditDirectory.appendingPathComponent(filename)

            try SecureStorage.writeEncrypted(data, to: fileURL)
            print("[AuditLog] Persisted \(currentSegment.count) entries to \(filename)")
            currentSegment.removeAll()

            // Clean up old segments
            cleanupOldSegments()
        } catch {
            print("[AuditLog] Failed to persist: \(error.localizedDescription)")
        }
    }

    /// Rotate: persist current segment and start a new one.
    private func rotateSegment() {
        persistToDisk()
    }

    /// Delete audit segments older than retention period.
    private func cleanupOldSegments() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(retentionDays * 86400))

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: auditDirectory, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        for file in files where file.pathExtension == "enc" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let created = attrs[.creationDate] as? Date,
               created < cutoff {
                try? FileManager.default.removeItem(at: file)
                print("[AuditLog] Cleaned up old segment: \(file.lastPathComponent)")
            }
        }
    }

    /// Load historical audit entries from encrypted segments.
    func loadHistory(days: Int = 7) -> [Entry] {
        let cutoff = Date().addingTimeInterval(-TimeInterval(days * 86400))

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: auditDirectory, includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }

        var allEntries: [Entry] = []

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "enc" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let created = attrs[.creationDate] as? Date,
               created >= cutoff {
                do {
                    let data = try SecureStorage.readEncrypted(from: file)
                    let entries = try JSONDecoder().decode([Entry].self, from: data)
                    allEntries.append(contentsOf: entries)
                } catch {
                    print("[AuditLog] Failed to read \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        return allEntries
    }

    /// Disk usage of audit segments in bytes.
    func diskUsage() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: auditDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(0) { sum, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            return sum + size
        }
    }
}
