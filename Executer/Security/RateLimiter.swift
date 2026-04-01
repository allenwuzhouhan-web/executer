import Foundation

/// Actor-based sliding window rate limiter for security-sensitive operations.
actor RateLimiter {
    static let shared = RateLimiter()

    /// Sliding window of timestamps per operation key.
    private var attempts: [String: [Date]] = [:]

    /// Rate limit configurations: (maxAttempts, windowSeconds).
    private let limits: [String: (max: Int, window: TimeInterval)] = [
        "biometric_auth": (max: 5, window: 60),
        "manifest_check": (max: 1, window: 300),
        "integrity_manual": (max: 3, window: 300),
    ]

    /// Default per-tool execution rate limit.
    private let toolExecutionLimit = (max: 100, window: TimeInterval(60))

    /// Check if an operation is within its rate limit.
    /// Returns true if allowed, false if rate-limited.
    func check(operation: String) -> Bool {
        let now = Date()
        let limit = limits[operation] ?? toolExecutionLimit
        pruneExpired(operation: operation, before: now.addingTimeInterval(-limit.window))
        let count = attempts[operation]?.count ?? 0
        return count < limit.max
    }

    /// Check rate limit for a specific tool execution.
    func checkToolExecution(toolName: String) -> Bool {
        let key = "tool_exec_\(toolName)"
        let now = Date()
        pruneExpired(operation: key, before: now.addingTimeInterval(-toolExecutionLimit.window))
        let count = attempts[key]?.count ?? 0
        return count < toolExecutionLimit.max
    }

    /// Record an attempt for an operation.
    func recordAttempt(operation: String) {
        if attempts[operation] == nil {
            attempts[operation] = []
        }
        attempts[operation]?.append(Date())
    }

    /// Record a tool execution attempt.
    func recordToolExecution(toolName: String) {
        let key = "tool_exec_\(toolName)"
        recordAttempt(operation: key)
    }

    /// Reset attempts for an operation (e.g., after successful auth).
    func reset(operation: String) {
        attempts[operation] = nil
    }

    /// Get remaining attempts for an operation.
    func remainingAttempts(operation: String) -> Int {
        let limit = limits[operation] ?? toolExecutionLimit
        let now = Date()
        pruneExpired(operation: operation, before: now.addingTimeInterval(-limit.window))
        let count = attempts[operation]?.count ?? 0
        return max(0, limit.max - count)
    }

    // MARK: - Private

    private func pruneExpired(operation: String, before cutoff: Date) {
        attempts[operation]?.removeAll { $0 < cutoff }
    }
}
