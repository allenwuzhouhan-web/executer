import Foundation

/// Utilities for safe construction of shell commands and AppleScript strings.
enum ShellSanitizer {
    /// Escapes a string for safe inclusion in a double-quoted shell argument.
    /// Handles: backslash, double-quote, backtick, dollar sign, exclamation mark, newline, carriage return.
    static func escapeForDoubleQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "`", with: "\\`")
         .replacingOccurrences(of: "$", with: "\\$")
         .replacingOccurrences(of: "!", with: "\\!")
         .replacingOccurrences(of: "\n", with: "")
         .replacingOccurrences(of: "\r", with: "")
    }

    /// Escapes a string for safe inclusion in a single-quoted shell argument.
    static func escapeForSingleQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Validates that a string is a safe app/voice name (no shell metacharacters).
    static func isValidAppName(_ s: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) } && !s.isEmpty && s.count < 100
    }

    /// Validates that a string looks like a file extension (letters and digits only).
    static func isValidFileExtension(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil
    }
}
