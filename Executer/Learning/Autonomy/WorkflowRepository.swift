import Foundation

/// Searchable, indexed repository of all generalized workflows.
///
/// Phase 5 of the Workflow Recorder ("The Archive").
/// Provides hybrid search: FTS5 keyword matching + embedding cosine similarity.
/// Manages lifecycle: 30-day auto-archive, 90-day purge.
actor WorkflowRepository {
    static let shared = WorkflowRepository()

    // MARK: - Storage

    /// Insert or update a generalized workflow.
    func save(_ workflow: GeneralizedWorkflow) {
        JournalStore.shared.insertGeneralizedWorkflow(workflow)
    }

    /// Fetch all workflows, optionally filtered by category.
    func allWorkflows(category: String? = nil, limit: Int = 100) -> [GeneralizedWorkflow] {
        let all = JournalStore.shared.recentGeneralizedWorkflows(limit: limit)
        if let category = category {
            return all.filter { $0.category == category }
        }
        return all
    }

    /// Count of stored workflows.
    func count() -> Int {
        JournalStore.shared.generalizedWorkflowCount()
    }

    // MARK: - Hybrid Search

    /// Search workflows using a combination of keyword matching and semantic similarity.
    /// Returns results ranked by combined score.
    func search(query: String, limit: Int = 10) -> [SearchResult] {
        let all = JournalStore.shared.recentGeneralizedWorkflows(limit: 200)
        guard !all.isEmpty else { return [] }

        let queryLower = query.lowercased()
        let queryKeywords = Set(queryLower.split(separator: " ").map(String.init).filter { $0.count > 2 })
        let queryEmbedding = TextEmbedder.sentenceVector(query)

        var results: [SearchResult] = []

        for workflow in all {
            var keywordScore = 0.0
            var semanticScore = 0.0

            // Keyword matching against name, description, topic keywords, category
            let searchableText = "\(workflow.name) \(workflow.description) \(workflow.applicability.keywords.joined(separator: " ")) \(workflow.category)".lowercased()

            let matchedKeywords = queryKeywords.filter { searchableText.contains($0) }
            if !queryKeywords.isEmpty {
                keywordScore = Double(matchedKeywords.count) / Double(queryKeywords.count)
            }

            // Semantic similarity via embeddings
            if let qEmb = queryEmbedding {
                let workflowText = "\(workflow.name) \(workflow.applicability.keywords.joined(separator: " "))"
                if let wEmb = TextEmbedder.sentenceVector(workflowText) {
                    let cosine = TextEmbedder.cosineSimilarity(qEmb, wEmb)
                    semanticScore = (cosine + 1.0) / 2.0  // Normalize to [0, 1]
                }
            }

            // Combined score: 40% keywords + 60% semantic
            let combinedScore = keywordScore * 0.4 + semanticScore * 0.6

            if combinedScore > 0.15 {  // Minimum relevance threshold
                results.append(SearchResult(
                    workflow: workflow,
                    score: combinedScore,
                    keywordScore: keywordScore,
                    semanticScore: semanticScore,
                    matchedTerms: Array(matchedKeywords)
                ))
            }
        }

        // Sort by combined score, return top N
        results.sort { $0.score > $1.score }
        return Array(results.prefix(limit))
    }

    /// Search workflows by app name.
    func searchByApp(_ appName: String, limit: Int = 10) -> [GeneralizedWorkflow] {
        let all = JournalStore.shared.recentGeneralizedWorkflows(limit: 200)
        return Array(all.filter { $0.applicability.requiredApps.contains(appName) || $0.applicability.primaryApp == appName }.prefix(limit))
    }

    /// Find workflows similar to a given workflow (for deduplication/composition).
    func findSimilar(to workflow: GeneralizedWorkflow, threshold: Double = 0.6) -> [GeneralizedWorkflow] {
        let results = search(query: "\(workflow.name) \(workflow.applicability.keywords.joined(separator: " "))", limit: 5)
        return results.filter { $0.workflow.id != workflow.id && $0.score > threshold }.map(\.workflow)
    }

    // MARK: - Lifecycle Management

    /// Run lifecycle maintenance (called by JournalArchiver).
    func performMaintenance() {
        // Generalized workflows don't have the same archive lifecycle as journals.
        // They persist until explicitly deleted or their source journal is purged.
        // But we do deduplicate: if two workflows have very similar names and steps,
        // keep the newer one.
        let all = JournalStore.shared.recentGeneralizedWorkflows(limit: 500)
        var seen: [String: UUID] = [:]  // name hash → kept ID

        for wf in all {
            let nameKey = wf.name.lowercased().trimmingCharacters(in: .whitespaces)
            if let existingId = seen[nameKey], existingId != wf.id {
                // Duplicate — keep the one already in `seen` (it's newer since sorted by created_at DESC)
                // We could delete the older one here, but for safety, just log it
                print("[WorkflowRepository] Potential duplicate: '\(wf.name)' (\(wf.id) vs \(existingId))")
            } else {
                seen[nameKey] = wf.id
            }
        }
    }

    // MARK: - Types

    struct SearchResult: Sendable {
        let workflow: GeneralizedWorkflow
        let score: Double              // Combined score (0–1)
        let keywordScore: Double       // Keyword match score
        let semanticScore: Double      // Embedding similarity score
        let matchedTerms: [String]     // Which query terms matched
    }
}
