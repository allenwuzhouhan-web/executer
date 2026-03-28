import Foundation

/// Parses messaging commands into (contact, message, platform) tuples.
/// Runs synchronously on the main thread — no async, no actor, no race conditions.
enum MessageParser {

    /// Try to parse a command as a messaging intent.
    /// Returns (contact, message, platform) if matched, nil otherwise.
    /// Platform is nil for generic commands ("tell mom hi") — caller uses preferred platform.
    /// Preserves original casing from the user's input.
    static func parse(_ command: String) -> (contact: String, message: String, platform: MessagingPlatform?)? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Platform-specific prefixes (checked first)
        let platformPrefixes: [(String, MessagingPlatform)] = [
            ("use wechat to tell ", .wechat), ("use wechat to message ", .wechat), ("use wechat to text ", .wechat),
            ("wechat message ", .wechat), ("wechat ", .wechat),
            ("use imessage to tell ", .imessage), ("use imessage to message ", .imessage), ("use imessage to text ", .imessage),
            ("imessage ", .imessage), ("iMessage ", .imessage), ("text via imessage ", .imessage),
            ("use whatsapp to tell ", .whatsapp), ("use whatsapp to message ", .whatsapp), ("use whatsapp to text ", .whatsapp),
            ("whatsapp message ", .whatsapp), ("whatsapp ", .whatsapp), ("wa ", .whatsapp),
        ]

        for (prefix, platform) in platformPrefixes {
            guard lower.hasPrefix(prefix) else { continue }
            let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if var result = splitContactAndMessage(rest) {
                stripConnectors(&result)
                return (result.contact, result.message, platform)
            }
        }

        // Chinese with platform: "微信给X发Y"
        if lower.hasPrefix("微信") {
            let rest = String(trimmed.dropFirst(2))
            if let result = parseChinesePattern(rest, splitChar: "发", prefix: "给") {
                return (result.0, result.1, .wechat)
            }
        }

        // Generic prefixes (no explicit platform)
        let prefixes = [
            "tell ", "text ", "message ", "msg ",
            "send message to ", "send a message to ",
        ]

        for prefix in prefixes {
            guard lower.hasPrefix(prefix) else { continue }
            let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if var result = splitContactAndMessage(rest) {
                stripConnectors(&result)
                return (result.contact, result.message, nil)
            }
        }

        // Chinese: "给X发Y" / "跟X说Y" (no explicit platform)
        if let result = parseChinesePattern(trimmed, splitChar: "发", prefix: "给") {
            return (result.0, result.1, nil)
        }
        if let result = parseChinesePattern(trimmed, splitChar: "说", prefix: "跟") {
            return (result.0, result.1, nil)
        }

        return nil
    }

    private static func stripConnectors(_ result: inout (contact: String, message: String)) {
        let msgLower = result.message.lowercased()
        for connector in ["that ", "to "] {
            if msgLower.hasPrefix(connector) {
                result.message = String(result.message.dropFirst(connector.count))
                break
            }
        }
    }

    // Words that signal the start of the message, never part of a contact name
    private static let messageStartWords: Set<String> = [
        "that", "to", "the", "a", "an", "about", "and",
        "i", "i'll", "i'm", "im", "hey", "hi", "hello", "yo",
        "he", "she", "we", "they", "it", "its", "it's",
        "please", "pls", "plz", "can", "could", "would", "will", "should",
        "don't", "dont", "do", "did", "is", "are", "was",
        "thanks", "thank", "thx", "sorry",
        "our", "my", "your", "his", "her", "their",
        "not", "no", "yes", "ok", "okay",
        "there", "here", "where", "when", "what", "how", "why",
    ]

    // MARK: - Helpers

    private static func parseChinesePattern(_ text: String, splitChar: Character, prefix: String) -> (String, String)? {
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard let splitIdx = rest.firstIndex(of: splitChar) else { return nil }
        let contact = String(rest[rest.startIndex..<splitIdx]).trimmingCharacters(in: .whitespaces)
        let message = String(rest[rest.index(after: splitIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !contact.isEmpty && !message.isEmpty else { return nil }
        return (contact, message)
    }

    /// Split "Allen Woo hey what's up" into (contact, message).
    private static func splitContactAndMessage(_ text: String) -> (contact: String, message: String)? {
        let words = text.components(separatedBy: " ")
        guard words.count >= 2 else { return nil }

        // Check known contacts first (longest match, case-insensitive)
        let knownContacts = MessageRouter.shared.allContacts()
        for contact in knownContacts.sorted(by: { $0.count > $1.count }) {
            if text.lowercased().hasPrefix(contact.lowercased()) {
                let afterContact = String(text.dropFirst(contact.count)).trimmingCharacters(in: .whitespaces)
                if !afterContact.isEmpty {
                    // Return the original-cased contact name from the routes
                    return (contact, afterContact)
                }
            }
        }

        // Heuristic: try 2-word name only if the second word is also capitalized
        // "Allen Woo hey" → name="Allen Woo", msg="hey"
        // "RangerZ that I'm late" → name="RangerZ", msg="that I'm late"
        if words.count >= 3 {
            let secondWord = words[1]
            let secondIsName = secondWord.first?.isUppercase == true && !messageStartWords.contains(secondWord.lowercased())
            if secondIsName {
                let twoWordName = "\(words[0]) \(words[1])"
                let message = words[2...].joined(separator: " ")
                if !message.isEmpty {
                    return (twoWordName, message)
                }
            }
        }

        // 1-word contact name
        let contact = words[0]
        let message = words[1...].joined(separator: " ")
        return message.isEmpty ? nil : (contact, message)
    }
}
