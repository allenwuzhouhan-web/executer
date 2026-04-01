import Foundation

/// Tool: train_document — Drop a file and deeply study its structure, style, and content.
/// Runs the 3-agent pipeline (Planner → Critic → Writer).
struct TrainDocumentTool: ToolDefinition {
    var name: String { "train_document" }

    var description: String {
        "Deeply study a document (PPTX, DOCX, KEY, PDF, etc.) to learn its structure, style, content, and design patterns. " +
        "Uses a 3-agent pipeline (Planner → Critic → Writer) to rigorously analyze the document and produce a leveled bullet summary. " +
        "The learned knowledge is stored and used to improve future document creation and understanding."
    }

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the document file to study"),
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            return "Error: File not found at \(path)"
        }

        let ext = url.pathExtension.lowercased()
        let supported = ["pptx", "docx", "doc", "key", "pages", "pdf", "xlsx", "xls", "numbers", "txt", "md", "rtf"]
        guard supported.contains(ext) else {
            return "Error: Unsupported format '\(ext)'. Supported: \(supported.joined(separator: ", "))"
        }

        do {
            let profile = try await DocumentTrainer.shared.train(fileURL: url) { progress in
                print("[Trainer] \(progress)")
            }

            // Format the result as leveled bullets
            var output = "# Document Training Complete: \(profile.sourceFile)\n\n"
            output += "**Quality Score:** \(String(format: "%.0f", profile.qualityScore * 100))%\n"
            if let notes = profile.qualityNotes { output += "**Quality:** \(notes)\n" }
            output += "\n## Summary\n"
            output += "\(profile.summary.oneLiner)\n\n"

            for bullet in profile.summary.bullets {
                let indent = String(repeating: "  ", count: bullet.level)
                let marker = bullet.importance == "critical" ? "**" : ""
                output += "\(indent)- \(marker)\(bullet.text)\(marker)\n"
            }

            output += "\n## Study Recommendation\n"
            output += profile.summary.studyRecommendation
            output += "\n\n---\n"
            output += "Structure: \(profile.structure.totalSections) sections, \(profile.structure.flowPattern) flow\n"
            output += "Domain: \(profile.content.domain) (\(profile.content.audienceLevel))\n"
            output += "Key terms: \(profile.content.keyTerms.count) | Design patterns: \(profile.designPatterns.count)\n"
            output += "Teaching approach: \(profile.content.teachingApproach)"

            return output
        } catch {
            return "Training failed: \(error.localizedDescription)"
        }
    }
}

/// Tool: list_trained_documents — Show all documents the agent has studied.
struct ListTrainedDocumentsTool: ToolDefinition {
    var name: String { "list_trained_documents" }

    var description: String {
        "List all documents that have been studied via the document trainer, " +
        "showing filename, format, quality score, main topic, and one-line summary."
    }

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:], required: [])
    }

    func execute(arguments: String) async throws -> String {
        let profiles = DocumentStudyStore.shared.profiles
        guard !profiles.isEmpty else {
            return "No documents have been trained yet. Use train_document to study a file."
        }

        var output = "# Trained Documents (\(profiles.count))\n\n"
        for p in profiles {
            let quality = String(format: "%.0f%%", p.qualityScore * 100)
            output += "- **\(p.sourceFile)** (\(p.sourceFormat)) — Quality: \(quality)\n"
            output += "  \(p.summary.oneLiner)\n"
            output += "  Domain: \(p.content.domain) | \(p.content.keyTerms.count) terms | \(p.structure.totalSections) sections\n\n"
        }

        return output
    }
}

/// Tool: recall_trained_knowledge — Search across all trained documents for specific knowledge.
struct RecallTrainedKnowledgeTool: ToolDefinition {
    var name: String { "recall_trained_knowledge" }

    var description: String {
        "Search across all trained document knowledge for a specific topic, term, or concept. " +
        "Returns relevant information from the best-quality sources."
    }

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Topic, term, or concept to search for"),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let queryLower = query.lowercased()

        let profiles = DocumentStudyStore.shared.profiles
        guard !profiles.isEmpty else {
            return "No trained documents available. Use train_document first."
        }

        var matches: [(profile: DocumentStudyProfile, relevance: Int)] = []

        for profile in profiles {
            var relevance = 0

            // Check key terms
            for term in profile.content.keyTerms {
                if term.term.lowercased().contains(queryLower) { relevance += 3 }
                if term.definition?.lowercased().contains(queryLower) == true { relevance += 1 }
            }

            // Check topics
            if profile.content.mainTopic.lowercased().contains(queryLower) { relevance += 5 }
            for sub in profile.content.subtopics {
                if sub.lowercased().contains(queryLower) { relevance += 2 }
            }

            // Check takeaways
            for takeaway in profile.content.keyTakeaways {
                if takeaway.lowercased().contains(queryLower) { relevance += 1 }
            }

            if relevance > 0 { matches.append((profile, relevance)) }
        }

        matches.sort { $0.relevance > $1.relevance }

        guard !matches.isEmpty else {
            return "No trained knowledge found for '\(query)'. Available domains: \(Set(profiles.map(\.content.domain)).joined(separator: ", "))"
        }

        var output = "# Knowledge for: \(query)\n\n"
        for match in matches.prefix(5) {
            let p = match.profile
            output += "## From: \(p.sourceFile) (quality: \(String(format: "%.0f%%", p.qualityScore * 100)))\n"

            // Relevant key terms
            let terms = p.content.keyTerms.filter {
                $0.term.lowercased().contains(queryLower) ||
                $0.definition?.lowercased().contains(queryLower) == true
            }
            for term in terms {
                output += "- **\(term.term)**: \(term.definition ?? "No definition")\n"
                if let ctx = term.context { output += "  Context: \(ctx)\n" }
            }

            // Relevant takeaways
            let takeaways = p.content.keyTakeaways.filter { $0.lowercased().contains(queryLower) }
            for t in takeaways { output += "- \(t)\n" }

            output += "\n"
        }

        return output
    }
}
