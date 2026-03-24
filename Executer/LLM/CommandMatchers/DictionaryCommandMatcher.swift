import Foundation

extension LocalCommandRouter {

    func tryDictionaryCommand(_ input: String) async -> String? {
        // "define [word]" / "definition of [word]" / "what does [word] mean"
        let definePrefixes = ["define ", "definition of ", "definition for "]
        for prefix in definePrefixes {
            if input.hasPrefix(prefix) {
                let word = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !word.isEmpty {
                    return try? await DictionaryLookupTool().execute(arguments: "{\"word\": \"\(escapeJSON(word))\"}")
                }
            }
        }

        // "what does [word] mean"
        if input.hasPrefix("what does ") && input.hasSuffix(" mean") {
            let word = String(input.dropFirst("what does ".count).dropLast(" mean".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                return try? await DictionaryLookupTool().execute(arguments: "{\"word\": \"\(escapeJSON(word))\"}")
            }
        }

        // "what's the meaning of [word]"
        if input.hasPrefix("what's the meaning of ") || input.hasPrefix("whats the meaning of ") {
            let prefix = input.hasPrefix("what's") ? "what's the meaning of " : "whats the meaning of "
            let word = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                return try? await DictionaryLookupTool().execute(arguments: "{\"word\": \"\(escapeJSON(word))\"}")
            }
        }

        // "synonym for [word]" / "synonyms of [word]"
        let synPrefixes = ["synonym for ", "synonyms for ", "synonyms of ", "synonym of ",
                           "another word for ", "similar word to ", "similar words to "]
        for prefix in synPrefixes {
            if input.hasPrefix(prefix) {
                let word = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !word.isEmpty {
                    return try? await ThesaurusLookupTool().execute(arguments: "{\"word\": \"\(escapeJSON(word))\"}")
                }
            }
        }

        // "spell check [text]" / "how do you spell [word]" / "is [word] spelled right"
        if input.hasPrefix("spell check ") || input.hasPrefix("spellcheck ") {
            let text = input.replacingOccurrences(of: "spell check ", with: "")
                .replacingOccurrences(of: "spellcheck ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return try? await SpellCheckTool().execute(arguments: "{\"text\": \"\(escapeJSON(text))\"}")
            }
        }
        if input.hasPrefix("how do you spell ") {
            let word = String(input.dropFirst("how do you spell ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                return try? await SpellCheckTool().execute(arguments: "{\"text\": \"\(escapeJSON(word))\"}")
            }
        }

        return nil
    }

    func tryTranslation(_ input: String) async -> String? {
        // This catches "translate X to Y" but we return nil to let the LLM handle
        // the actual translation. The point is to NOT do research — just translate.
        // The LLM will handle it as a simple task.
        return nil
    }
}
