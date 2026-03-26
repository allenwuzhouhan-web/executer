import Foundation

/// In-memory ring buffer of security-relevant tool executions.
actor AuditLog {
    static let shared = AuditLog()

    struct Entry {
        let date: Date
        let tool: String
        let tier: ToolRiskTier
        let argPreview: String
        let resultPreview: String
    }

    private let maxEntries = 1000
    private var entries: [Entry] = []

    func log(tool: String, args: String, result: String, tier: ToolRiskTier) {
        let entry = Entry(
            date: Date(),
            tool: tool,
            tier: tier,
            argPreview: String(args.prefix(200)),
            resultPreview: String(result.prefix(200))
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // Print elevated+ to console for visibility
        if tier >= .elevated {
            print("[SECURITY] \(tier) tool: \(tool) — args: \(String(args.prefix(100)))")
        }
    }

    /// Returns recent entries (for diagnostics / future audit UI).
    func recentEntries(count: Int = 50) -> [Entry] {
        Array(entries.suffix(count))
    }
}
