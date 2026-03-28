import Foundation

/// Extracts semantic observations from code editors (VS Code, Xcode, Cursor, JetBrains).
/// Pays attention to: active project, programming language, files, terminal output.
struct CodeEditorExtractor: AttentionExtractor {
    var appPatterns: [String] { ["xcode", "vs code", "visual studio code", "code", "cursor", "intellij", "pycharm", "webstorm", "goland", "clion", "rider", "android studio", "nova", "sublime", "atom"] }

    func extract(actions: [UserAction], screenText: [String]?, appName: String) -> [SemanticObservation] {
        var details: [String: String] = [:]
        var topics: [String] = []

        // Extract project/file info from window titles
        // Common formats: "file.swift — ProjectName", "ProjectName — file.swift"
        for action in actions where action.type == .windowOpen || action.type == .focus {
            let title = action.elementTitle

            // Extract file extension for language detection
            let fileExtensions: [String: String] = [
                ".swift": "Swift", ".py": "Python", ".js": "JavaScript",
                ".ts": "TypeScript", ".rs": "Rust", ".go": "Go",
                ".java": "Java", ".rb": "Ruby", ".cpp": "C++",
                ".c": "C", ".tsx": "React/TSX", ".jsx": "React/JSX",
            ]
            for (ext, lang) in fileExtensions {
                if title.contains(ext) {
                    details["language"] = lang
                    break
                }
            }

            // Extract project name from title (before or after " — ")
            if title.contains(" — ") {
                let parts = title.components(separatedBy: " — ")
                if parts.count >= 2 {
                    details["project"] = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
                }
            }
        }

        // Extract topics from visible text
        if let screenText = screenText {
            let codeText = screenText.joined(separator: " ")
            topics = NLPipeline.extractKeywords(from: codeText, limit: 5)
        }

        if let project = details["project"] {
            topics.append(project)
        }
        if let lang = details["language"] {
            topics.append(lang)
        }

        guard !topics.isEmpty || !details.isEmpty else { return [] }

        var intent = "Coding"
        if let lang = details["language"] { intent += " in \(lang)" }
        if let project = details["project"] { intent += " on \(project)" }

        return [SemanticObservation(
            appName: appName,
            category: .coding,
            intent: intent,
            details: details,
            relatedTopics: Array(Set(topics)),
            confidence: 0.8
        )]
    }
}
