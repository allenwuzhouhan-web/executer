import Foundation
import CoreServices
import AppKit

// MARK: - Dictionary Lookup (macOS native — instant, no API)

struct DictionaryLookupTool: ToolDefinition {
    let name = "dictionary_lookup"
    let description = "Look up a word definition, synonym, or translation using the native macOS dictionary. Instant, offline, no API call needed."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "word": JSONSchema.string(description: "The word or phrase to look up"),
        ], required: ["word"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let word = try requiredString("word", from: args)

        // Use macOS native DCSCopyTextDefinition for instant dictionary lookup
        let nsWord = word as NSString
        let range = CFRangeMake(0, nsWord.length)

        if let definition = DCSCopyTextDefinition(nil, nsWord, range)?.takeRetainedValue() as String? {
            // Clean up the definition — trim excess whitespace and limit length
            let cleaned = definition
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Cap at a reasonable length for the response bubble
            if cleaned.count > 500 {
                return String(cleaned.prefix(500)) + "..."
            }
            return cleaned
        }

        return "No definition found for '\(word)'."
    }
}

// MARK: - Thesaurus (synonyms via macOS dictionary)

struct ThesaurusLookupTool: ToolDefinition {
    let name = "thesaurus_lookup"
    let description = "Find synonyms for a word using the native macOS thesaurus. Instant, offline."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "word": JSONSchema.string(description: "The word to find synonyms for"),
        ], required: ["word"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let word = try requiredString("word", from: args)

        // macOS Dictionary.app includes a thesaurus — access via AppleScript
        let script = """
        tell application "Dictionary"
            -- Don't bring to front, just look up
        end tell
        """
        // Silently ensure Dictionary is available
        _ = AppleScriptRunner.run(script)

        // Use DCSCopyTextDefinition which includes thesaurus data when available
        let nsWord = word as NSString
        let range = CFRangeMake(0, nsWord.length)

        if let definition = DCSCopyTextDefinition(nil, nsWord, range)?.takeRetainedValue() as String? {
            // Try to extract synonym section
            let lower = definition.lowercased()
            if let synRange = lower.range(of: "synonym") ?? lower.range(of: "similar") {
                let fromSyn = String(definition[synRange.lowerBound...])
                let lines = fromSyn.components(separatedBy: "\n").prefix(5)
                return "**Synonyms for '\(word)':**\n" + lines.joined(separator: "\n")
            }

            // If no explicit synonym section, return the full definition
            let cleaned = definition.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count > 400 {
                return String(cleaned.prefix(400)) + "..."
            }
            return cleaned
        }

        return "No synonyms found for '\(word)'."
    }
}

// MARK: - Spell Check (native macOS)

struct SpellCheckTool: ToolDefinition {
    let name = "spell_check"
    let description = "Check spelling of a word and suggest corrections using native macOS spell checker"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "text": JSONSchema.string(description: "The text to spell-check"),
        ], required: ["text"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let text = try requiredString("text", from: args)

        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: text.utf16.count)
        let misspelledRange = checker.checkSpelling(of: text, startingAt: 0)

        if misspelledRange.location == NSNotFound {
            return "'\(text)' is spelled correctly."
        }

        // Get the misspelled word
        let nsText = text as NSString
        let misspelled = nsText.substring(with: misspelledRange)

        // Get suggestions
        let language: String? = nil
        let guesses = checker.guesses(forWordRange: misspelledRange, in: text, language: language, inSpellDocumentWithTag: 0) ?? []

        if guesses.isEmpty {
            return "'\(misspelled)' may be misspelled. No suggestions available."
        }

        let suggestions = guesses.prefix(5).joined(separator: ", ")
        return "'\(misspelled)' → did you mean: **\(suggestions)**?"
    }
}
