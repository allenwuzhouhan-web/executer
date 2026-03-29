import Foundation

/// Filters sensitive content from observations before storage.
/// The architecture mandates "patterns, not data" — this ensures raw text
/// is never stored; only categories and lengths.
enum ContentFilter {

    // MARK: - Content Categories

    enum ContentCategory: String {
        case prose         // General text
        case code          // Programming code
        case url           // Web URLs
        case email         // Email addresses
        case credential    // API keys, tokens, passwords
        case financial     // Credit cards, bank numbers
        case identifier    // SSN, ID numbers
        case phone         // Phone numbers
        case uiLabel       // Short UI element labels (<20 chars)
        case empty         // No content
    }

    // MARK: - Pre-compiled Regexes (compiled once, reused)

    private static let creditCardRegex = try! NSRegularExpression(pattern: #"\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b"#)
    private static let apiKeyRegex = try! NSRegularExpression(pattern: #"(sk-[a-zA-Z0-9]{20,}|AIza[a-zA-Z0-9_-]{35}|eyJ[a-zA-Z0-9_-]{20,}|ghp_[a-zA-Z0-9]{36}|Bearer\s+[a-zA-Z0-9._-]{20,})"#)
    private static let emailRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#)
    private static let ssnRegex = try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)
    private static let phoneRegex = try! NSRegularExpression(pattern: #"\b(\+?1?[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"#)
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s]+"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"(func |class |struct |import |var |let |if |for |while |return |def |const |=>)"#)

    // MARK: - Sanitization

    /// Classify text and return category + length. NEVER returns raw content.
    /// This is the primary method called before storing observations.
    static func sanitize(_ value: String) -> String {
        guard !value.isEmpty else { return "empty:0" }
        let category = classify(value)
        return "\(category.rawValue):\(value.count)"
    }

    /// Classify text into a content category.
    static func classify(_ text: String) -> ContentCategory {
        guard !text.isEmpty else { return .empty }

        let range = NSRange(text.startIndex..., in: text)

        // Check sensitive patterns first (highest priority)
        if creditCardRegex.firstMatch(in: text, range: range) != nil { return .financial }
        if ssnRegex.firstMatch(in: text, range: range) != nil { return .identifier }
        if apiKeyRegex.firstMatch(in: text, range: range) != nil { return .credential }
        if emailRegex.firstMatch(in: text, range: range) != nil { return .email }
        if phoneRegex.firstMatch(in: text, range: range) != nil { return .phone }

        // Check content type
        if urlRegex.firstMatch(in: text, range: range) != nil { return .url }
        if codeRegex.firstMatch(in: text, range: range) != nil { return .code }

        // Short text is likely a UI label
        if text.count < 20 { return .uiLabel }

        return .prose
    }

    /// Check if text contains any sensitive data.
    static func containsSensitiveData(_ text: String) -> Bool {
        let category = classify(text)
        return [.financial, .identifier, .credential, .email, .phone].contains(category)
    }

    /// Redact sensitive patterns in text, replacing with [REDACTED:<type>].
    static func redact(_ text: String) -> String {
        var result = text
        let range = NSRange(text.startIndex..., in: text)

        // Redact in order of specificity
        let replacements: [(NSRegularExpression, String)] = [
            (creditCardRegex, "[REDACTED:card]"),
            (ssnRegex, "[REDACTED:ssn]"),
            (apiKeyRegex, "[REDACTED:key]"),
            (emailRegex, "[REDACTED:email]"),
            (phoneRegex, "[REDACTED:phone]"),
        ]

        for (regex, replacement) in replacements {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }

        return result
    }
}
