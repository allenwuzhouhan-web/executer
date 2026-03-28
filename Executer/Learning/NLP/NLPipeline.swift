import Foundation
import NaturalLanguage

/// Central NLP pipeline wrapping Apple's NaturalLanguage framework.
/// All processing runs on-device via the Neural Engine on Apple Silicon.
/// Zero API calls — completely local and private.
enum NLPipeline {

    // MARK: - Language Detection

    /// Detect the dominant language of the given text.
    static func detectLanguage(_ text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    // MARK: - Tokenization

    /// Extract meaningful words (nouns, verbs, adjectives) from text.
    /// Filters out stopwords and function words using POS tagging.
    static func extractKeywords(from text: String, limit: Int = 20) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text

        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
        let desiredTags: Set<NLTag> = [.noun, .verb, .adjective, .personalName, .organizationName, .placeName]

        var keywords: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            if let tag = tag, desiredTags.contains(tag) {
                let word = String(text[range]).lowercased()
                if word.count > 2 && !keywords.contains(word) {
                    keywords.append(word)
                }
            }
            return keywords.count < limit
        }

        return keywords
    }

    // MARK: - Named Entity Recognition

    /// Extract named entities (people, organizations, places) from text.
    static func extractEntities(from text: String) -> [(value: String, type: NLTag)] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]
        let desiredTags: Set<NLTag> = [.personalName, .organizationName, .placeName]

        var entities: [(String, NLTag)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag = tag, desiredTags.contains(tag) {
                let value = String(text[range])
                if !entities.contains(where: { $0.0 == value }) {
                    entities.append((value, tag))
                }
            }
            return true
        }

        return entities
    }

    // MARK: - Lemmatization

    /// Get the base (lemma) form of each word in the text.
    static func lemmatize(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text

        var lemmas: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let lemma = tag?.rawValue {
                lemmas.append(lemma.lowercased())
            } else {
                lemmas.append(String(text[range]).lowercased())
            }
            return true
        }

        return lemmas
    }

    // MARK: - Topic Extraction

    /// Extract the top topics from a collection of text strings.
    /// Returns keywords sorted by frequency across all texts.
    static func extractTopics(from texts: [String], limit: Int = 10) -> [String] {
        var frequency: [String: Int] = [:]

        for text in texts {
            let keywords = extractKeywords(from: text, limit: 30)
            for keyword in keywords {
                frequency[keyword, default: 0] += 1
            }
        }

        return frequency.sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}
