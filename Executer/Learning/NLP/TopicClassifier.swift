import Foundation

/// Classifies observed text and actions into high-level topic categories.
/// Used by the Attention system to understand what the user is working on.
enum TopicClassifier {

    /// High-level topic categories.
    enum Topic: String, Codable, CaseIterable {
        case coding = "coding"
        case writing = "writing"
        case design = "design"
        case research = "research"
        case communication = "communication"
        case dataAnalysis = "data_analysis"
        case browsing = "browsing"
        case media = "media"
        case productivity = "productivity"
        case other = "other"
    }

    /// Classify text into a topic based on keywords.
    static func classify(text: String, appName: String = "") -> Topic {
        let lower = text.lowercased() + " " + appName.lowercased()

        let scores: [(Topic, Int)] = Topic.allCases.map { topic in
            let keywords = topicKeywords[topic] ?? []
            let score = keywords.reduce(0) { count, keyword in
                count + (lower.contains(keyword) ? 1 : 0)
            }
            return (topic, score)
        }

        return scores.max(by: { $0.1 < $1.1 })?.0 ?? .other
    }

    /// Classify based on app name alone.
    static func classifyApp(_ appName: String) -> Topic {
        let lower = appName.lowercased()

        for (topic, apps) in appClassification {
            if apps.contains(where: { lower.contains($0) }) {
                return topic
            }
        }

        return .other
    }

    // MARK: - Classification Data

    private static let topicKeywords: [Topic: [String]] = [
        .coding: ["func ", "class ", "struct ", "import ", "var ", "let ", "git ", "commit", "branch", "debug", "error", "compile", "build", "test", "swift", "python", "javascript", "typescript", "react", "api"],
        .writing: ["document", "paragraph", "chapter", "draft", "edit", "review", "summary", "report", "essay", "article", "memo", "letter"],
        .design: ["font", "color", "layout", "slide", "canvas", "pixel", "gradient", "opacity", "layer", "artboard", "template", "style", "theme", "palette"],
        .research: ["search", "google", "wikipedia", "article", "paper", "study", "journal", "citation", "reference", "abstract", "findings"],
        .communication: ["message", "email", "chat", "slack", "reply", "inbox", "send", "compose", "thread", "channel"],
        .dataAnalysis: ["spreadsheet", "cell", "formula", "chart", "pivot", "filter", "sum", "average", "column", "row", "data", "graph"],
        .browsing: ["tab", "bookmark", "url", "http", "website", "page", "download"],
        .media: ["play", "pause", "video", "audio", "music", "podcast", "stream", "volume"],
        .productivity: ["calendar", "meeting", "task", "reminder", "deadline", "schedule", "agenda", "todo"],
    ]

    private static let appClassification: [Topic: [String]] = [
        .coding: ["xcode", "vs code", "visual studio", "cursor", "intellij", "pycharm", "webstorm", "terminal", "iterm", "warp"],
        .writing: ["pages", "word", "google docs", "textedit", "notion", "obsidian", "bear", "ulysses", "scrivener", "notes"],
        .design: ["keynote", "powerpoint", "figma", "sketch", "illustrator", "photoshop", "canva", "affinity"],
        .communication: ["mail", "outlook", "slack", "teams", "discord", "telegram", "wechat", "messages", "zoom"],
        .dataAnalysis: ["excel", "numbers", "google sheets", "tableau", "r studio"],
        .browsing: ["safari", "chrome", "firefox", "arc", "edge", "brave", "opera"],
        .media: ["spotify", "music", "vlc", "quicktime", "youtube", "netflix"],
        .productivity: ["calendar", "reminders", "todoist", "things", "omnifocus", "fantastical"],
    ]
}
