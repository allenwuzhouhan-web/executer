import Foundation

/// Redacts sensitive patterns from trace display strings.
/// Applied at display time only — full data preserved in memory.
enum TraceRedactor {

    private static let patterns: [(NSRegularExpression, String)] = {
        var list: [(NSRegularExpression, String)] = []
        // API keys: sk-..., key-..., Bearer tokens
        if let re = try? NSRegularExpression(pattern: #"(sk-|key-|Bearer\s+)[A-Za-z0-9_\-]{20,}"#) {
            list.append((re, "$1[REDACTED]"))
        }
        // Passwords in JSON: "password": "..."
        if let re = try? NSRegularExpression(pattern: #""(password|secret|token|api_key)"\s*:\s*"[^"]+""#, options: .caseInsensitive) {
            list.append((re, "\"$1\": \"[REDACTED]\""))
        }
        // Credit card patterns (4 groups of 4 digits)
        if let re = try? NSRegularExpression(pattern: #"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#) {
            list.append((re, "[card-number]"))
        }
        return list
    }()

    static func redact(_ text: String) -> String {
        var result = text
        let range = NSRange(result.startIndex..., in: result)
        for (regex, template) in patterns {
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
