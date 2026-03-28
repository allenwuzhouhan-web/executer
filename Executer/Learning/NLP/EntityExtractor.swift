import Foundation
import NaturalLanguage

/// Extracts structured entities from observed text.
/// Uses NLTagger for NER, runs on Neural Engine.
enum EntityExtractor {

    /// Entity types recognized by the extractor.
    enum EntityType: String, Codable {
        case person
        case organization
        case place
        case date
        case project  // Inferred from context (e.g., filenames, repo names)
    }

    /// A single extracted entity.
    struct Entity: Codable, Hashable {
        let value: String
        let type: EntityType
        let confidence: Double
    }

    /// Extract entities from a block of text.
    static func extract(from text: String) -> [Entity] {
        var entities: [Entity] = []

        // Use NaturalLanguage NER
        let nlEntities = NLPipeline.extractEntities(from: text)
        for (value, tag) in nlEntities {
            let type: EntityType
            switch tag {
            case .personalName: type = .person
            case .organizationName: type = .organization
            case .placeName: type = .place
            default: continue
            }
            entities.append(Entity(value: value, type: type, confidence: 0.8))
        }

        // Extract project names from common patterns
        // e.g., "MyProject.xcodeproj", "my-repo", filenames with extensions
        let projectPatterns = extractProjectNames(from: text)
        for name in projectPatterns {
            entities.append(Entity(value: name, type: .project, confidence: 0.6))
        }

        return entities
    }

    /// Extract potential project names from text (filenames, repo names, etc.)
    private static func extractProjectNames(from text: String) -> [String] {
        var names: Set<String> = []

        // Match common project file patterns
        let patterns = [
            "([A-Z][a-zA-Z0-9]+)\\.xcodeproj",    // Xcode projects
            "([a-zA-Z0-9_-]+)\\.xcworkspace",       // Xcode workspaces
            "([a-zA-Z][a-zA-Z0-9_-]+)/src/",        // Repo paths
            "~/[Dd]ocuments/[Ww]orks?/([^/\\s]+)",   // User's work folders
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                names.insert(String(text[range]))
            }
        }

        return Array(names)
    }
}
