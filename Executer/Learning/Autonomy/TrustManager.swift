import Foundation

/// Manages per-template trust levels for progressive autonomy.
final class TrustManager {
    static let shared = TrustManager()

    /// Trust levels per template ID.
    private var trustLevels: [UUID: TrustLevel] = [:]
    private let lock = NSLock()

    struct TrustLevel: Codable {
        var score: Double = 0.0           // 0.0–1.0
        var consecutiveSuccesses: Int = 0
        var consecutiveFailures: Int = 0
        var approvalRequired: Bool = true
    }

    /// Threshold for auto-approval (configurable by user).
    var autoApprovalThreshold: Double = 0.95
    var minSuccessesForAutoApproval: Int = 10

    private init() { loadTrustLevels() }

    /// Check if a template can be auto-approved.
    func canAutoApprove(templateId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let trust = trustLevels[templateId] else { return false }
        return trust.score >= autoApprovalThreshold &&
               trust.consecutiveSuccesses >= minSuccessesForAutoApproval &&
               !trust.approvalRequired
    }

    /// Record a successful execution.
    func recordSuccess(templateId: UUID) {
        lock.lock()
        var trust = trustLevels[templateId] ?? TrustLevel()
        trust.consecutiveSuccesses += 1
        trust.consecutiveFailures = 0
        trust.score = min(Double(trust.consecutiveSuccesses) / Double(minSuccessesForAutoApproval + 5), 1.0)

        // Auto-promote to no-approval after threshold
        if trust.score >= autoApprovalThreshold && trust.consecutiveSuccesses >= minSuccessesForAutoApproval {
            trust.approvalRequired = false
        }

        trustLevels[templateId] = trust
        lock.unlock()
        saveTrustLevels()
    }

    /// Record a failed execution.
    func recordFailure(templateId: UUID) {
        lock.lock()
        var trust = trustLevels[templateId] ?? TrustLevel()
        trust.consecutiveSuccesses = 0
        trust.consecutiveFailures += 1
        trust.score = max(trust.score - 0.2, 0)
        trust.approvalRequired = true // Reset to requiring approval
        trustLevels[templateId] = trust
        lock.unlock()
        saveTrustLevels()
    }

    /// Get trust level for a template.
    func trustLevel(for templateId: UUID) -> TrustLevel {
        lock.lock()
        defer { lock.unlock() }
        return trustLevels[templateId] ?? TrustLevel()
    }

    // MARK: - Persistence

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer", isDirectory: true)
        return dir.appendingPathComponent("trust_levels.json")
    }

    private func loadTrustLevels() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // UUID keys need special handling
        if let dict = try? JSONDecoder().decode([String: TrustLevel].self, from: data) {
            trustLevels = dict.reduce(into: [:]) { result, pair in
                if let uuid = UUID(uuidString: pair.key) {
                    result[uuid] = pair.value
                }
            }
        }
    }

    private func saveTrustLevels() {
        let stringDict = trustLevels.reduce(into: [String: TrustLevel]()) { $0[$1.key.uuidString] = $1.value }
        guard let data = try? JSONEncoder().encode(stringDict) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
