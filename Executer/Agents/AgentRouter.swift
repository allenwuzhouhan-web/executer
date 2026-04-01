import Foundation
import NaturalLanguage

/// Pre-routing layer that classifies user input into an agent profile.
/// Classification must complete in <10ms — uses keywords and NLTagger, never LLM calls.
enum AgentRouter {

    struct Decision {
        let agentId: String
        let strippedCommand: String   // command with agent prefix removed
        let confidence: Double        // 0.0-1.0
    }

    // MARK: - Explicit Prefix Patterns

    // "hey chem", "ask dev", "@daily", "chem:", "dev mode"
    private static let prefixPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:hey|ask|@)\s*(\w+)\b[,:]?\s*"#,
            options: [.caseInsensitive]
        )
    }()

    private static let modeSuffixPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(\w+)\s+mode\b[,:]?\s*"#,
            options: [.caseInsensitive]
        )
    }()

    // MARK: - Route

    /// Classify user input into an agent profile. Must be <10ms.
    static func route(_ command: String) -> Decision {
        let registry = AgentRegistry.shared
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Decision(agentId: "general", strippedCommand: trimmed, confidence: 1.0)
        }

        // Step 1: Explicit naming — "hey chem tell me about benzene"
        if let (agentId, stripped) = matchExplicitPrefix(trimmed, profiles: registry.allProfiles()) {
            return Decision(agentId: agentId, strippedCommand: stripped, confidence: 1.0)
        }

        // Step 2: Keyword scoring
        let scores = scoreByKeywords(trimmed, index: registry.keywordIndex)
        let sorted = scores.sorted { $0.value > $1.value }

        if let best = sorted.first, best.value >= 2 {
            // Check if it's clearly the winner (at least 1 point ahead of runner-up)
            let runnerUp = sorted.count > 1 ? sorted[1].value : 0
            if best.value - runnerUp >= 1 {
                return Decision(agentId: best.key, strippedCommand: trimmed, confidence: min(1.0, Double(best.value) / 5.0))
            }

            // Ambiguous — use NLTagger noun extraction for tiebreaker
            if let winner = tiebreakWithNLP(trimmed, candidates: sorted.prefix(2).map(\.key), registry: registry) {
                return Decision(agentId: winner, strippedCommand: trimmed, confidence: 0.6)
            }

            // Still ambiguous, go with keyword winner
            return Decision(agentId: best.key, strippedCommand: trimmed, confidence: 0.5)
        }

        // Step 3: Fallback to general
        return Decision(agentId: "general", strippedCommand: trimmed, confidence: 1.0)
    }

    // MARK: - Explicit Prefix Matching

    private static func matchExplicitPrefix(_ text: String, profiles: [AgentProfile]) -> (agentId: String, stripped: String)? {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        // "hey chem ...", "ask dev ...", "@daily ..."
        if let regex = prefixPattern,
           let match = regex.firstMatch(in: text, range: range) {
            let agentName = nsText.substring(with: match.range(at: 1)).lowercased()
            if let profile = profiles.first(where: { $0.id == agentName || $0.displayName.lowercased() == agentName }) {
                let stripped = nsText.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
                return (profile.id, stripped.isEmpty ? text : stripped)
            }
        }

        // "dev mode ...", "chem mode ..."
        if let regex = modeSuffixPattern,
           let match = regex.firstMatch(in: text, range: range) {
            let agentName = nsText.substring(with: match.range(at: 1)).lowercased()
            if let profile = profiles.first(where: { $0.id == agentName || $0.displayName.lowercased() == agentName }) {
                let stripped = nsText.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
                return (profile.id, stripped.isEmpty ? text : stripped)
            }
        }

        return nil
    }

    // MARK: - Keyword Scoring

    private static func scoreByKeywords(_ text: String, index: [String: Set<String>]) -> [String: Int] {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))

        var scores: [String: Int] = [:]
        for (agentId, keywords) in index {
            guard agentId != "general" else { continue }  // general is fallback, not scored

            // Count direct word matches
            var score = words.intersection(keywords).count

            // Check for multi-word keyword phrases (e.g., "periodic table", "stack trace")
            let lower = text.lowercased()
            for keyword in keywords where keyword.contains(" ") {
                if lower.contains(keyword) { score += 2 }  // phrase match worth more
            }

            if score > 0 {
                scores[agentId] = score
            }
        }

        return scores
    }

    // MARK: - NLP Tiebreaker

    private static func tiebreakWithNLP(_ text: String, candidates: [String], registry: AgentRegistry) -> String? {
        // Extract nouns using NLTagger
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text

        var nouns: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass) { tag, range in
            if tag == .noun || tag == .otherWord {
                let word = String(text[range]).lowercased()
                if word.count > 2 { nouns.append(word) }
            }
            return true
        }

        guard !nouns.isEmpty else { return nil }

        // Score each candidate by noun overlap with their keyword set
        var bestId: String?
        var bestScore = 0

        for candidateId in candidates {
            guard let keywords = registry.keywordIndex[candidateId] else { continue }
            let overlap = Set(nouns).intersection(keywords).count
            if overlap > bestScore {
                bestScore = overlap
                bestId = candidateId
            }
        }

        return bestId
    }
}
