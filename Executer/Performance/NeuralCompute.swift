import Foundation
import NaturalLanguage
import CoreML

/// Unified interface for on-device ML inference using Neural Engine when available.
enum NeuralCompute {
    private static var agentClassifier: NLModel?
    private static var isSetup = false

    /// Load models at app launch. Safe to call multiple times.
    static func setup() {
        guard !isSetup else { return }
        isSetup = true

        // Try to load compiled CoreML agent classifier from bundle
        if let url = Bundle.main.url(forResource: "AgentClassifier", withExtension: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all  // Let system pick Neural Engine when optimal
                let mlModel = try MLModel(contentsOf: url, configuration: config)
                agentClassifier = try NLModel(mlModel: mlModel)
                print("[NeuralCompute] Agent classifier loaded (Neural Engine enabled)")
            } catch {
                print("[NeuralCompute] Failed to load agent classifier: \(error.localizedDescription)")
            }
        } else {
            print("[NeuralCompute] No AgentClassifier.mlmodelc in bundle — using keyword fallback")
        }
    }

    // MARK: - Agent Classification

    /// Classify a user query into an agent ID using the CoreML model.
    /// Returns nil if the model is unavailable or confidence is too low.
    static func classifyAgent(_ query: String) -> (agentId: String, confidence: Double)? {
        guard let model = agentClassifier else { return nil }

        guard let label = model.predictedLabel(for: query) else { return nil }
        let hypotheses = model.predictedLabelHypotheses(for: query, maximumCount: 1)
        guard let confidence = hypotheses[label], confidence > 0.6 else { return nil }

        return (label, confidence)
    }

    // MARK: - Semantic Similarity

    /// Compute semantic similarity between two strings using Apple's NLEmbedding.
    /// Routes to Neural Engine automatically on Apple Silicon.
    /// Returns 0.0 to 1.0 (higher = more similar). Returns 0 if embeddings unavailable.
    static func textSimilarity(_ textA: String, _ textB: String, language: NLLanguage = .english) -> Double {
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else { return 0 }

        // Average word vectors for each text (simple but effective for short queries)
        let vecA = averageVector(text: textA, embedding: embedding)
        let vecB = averageVector(text: textB, embedding: embedding)

        guard let a = vecA, let b = vecB else { return 0 }
        return cosineSimilarity(a, b)
    }

    /// Batch similarity: score a query against multiple candidate strings.
    /// Returns array of (index, score) sorted by descending score.
    static func batchSimilarity(_ query: String, candidates: [String], language: NLLanguage = .english) -> [(index: Int, score: Double)] {
        guard let embedding = NLEmbedding.wordEmbedding(for: language),
              let queryVec = averageVector(text: query, embedding: embedding) else {
            return []
        }

        var results: [(index: Int, score: Double)] = []
        results.reserveCapacity(candidates.count)

        for (i, candidate) in candidates.enumerated() {
            if let candidateVec = averageVector(text: candidate, embedding: embedding) {
                let score = cosineSimilarity(queryVec, candidateVec)
                results.append((i, score))
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    // MARK: - Helpers

    private static func averageVector(text: String, embedding: NLEmbedding) -> [Double]? {
        let words = text.lowercased().split(separator: " ").map(String.init)
        var sum: [Double]?
        var count = 0

        for word in words {
            if let vec = embedding.vector(for: word) {
                if sum == nil {
                    sum = vec
                } else {
                    for i in sum!.indices { sum![i] += vec[i] }
                }
                count += 1
            }
        }

        guard var result = sum, count > 0 else { return nil }
        let scale = 1.0 / Double(count)
        for i in result.indices { result[i] *= scale }
        return result
    }

    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, magA = 0.0, magB = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }
}
