import Foundation
import CryptoKit

/// Detects infinite loops in tool execution and LLM calls.
/// Auto-pauses when the same operation repeats excessively.
enum LoopDetector {

    /// Ring buffer of recent tool calls.
    private static var recentCalls: [(hash: String, timestamp: Date)] = []
    /// Ring buffer of recent LLM prompts.
    private static var recentPrompts: [(hash: String, timestamp: Date)] = []
    private static let lock = NSLock()

    /// Maximum identical tool calls in a time window before triggering.
    private static let maxToolRepeats = 5
    /// Maximum identical LLM prompts before triggering.
    private static let maxPromptRepeats = 3
    /// Time window for detection (seconds).
    private static let windowSeconds: TimeInterval = 60

    /// Check if a tool call appears to be in a loop.
    /// Returns true if loop detected (caller should break).
    static func checkToolCall(toolName: String, arguments: String) -> Bool {
        let hash = hashString("\(toolName):\(arguments)")
        return checkLoop(hash: hash, buffer: &recentCalls, maxRepeats: maxToolRepeats)
    }

    /// Check if an LLM prompt appears to be in a loop.
    /// Returns true if loop detected (caller should break).
    static func checkPrompt(_ prompt: String) -> Bool {
        let hash = hashString(prompt)
        return checkLoop(hash: hash, buffer: &recentPrompts, maxRepeats: maxPromptRepeats)
    }

    /// Reset all detection state.
    static func reset() {
        lock.lock()
        recentCalls.removeAll()
        recentPrompts.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private static func checkLoop(hash: String, buffer: inout [(hash: String, timestamp: Date)], maxRepeats: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        // Prune old entries outside the window
        buffer.removeAll { now.timeIntervalSince($0.timestamp) > windowSeconds }

        // Add current entry
        buffer.append((hash, now))

        // Keep buffer size reasonable
        if buffer.count > 100 {
            buffer.removeFirst(buffer.count - 100)
        }

        // Count occurrences of this hash in the window
        let count = buffer.filter { $0.hash == hash }.count

        if count >= maxRepeats {
            print("[LoopDetector] Loop detected: hash \(hash.prefix(8))... repeated \(count) times in \(Int(windowSeconds))s")
            return true
        }

        return false
    }

    private static func hashString(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
