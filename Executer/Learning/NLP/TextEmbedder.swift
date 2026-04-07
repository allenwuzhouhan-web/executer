import Foundation
import NaturalLanguage
import Accelerate

/// On-device text embedding using NLEmbedding (runs on Neural Engine).
/// Uses Accelerate framework for fast cosine similarity on AMX coprocessor.
enum TextEmbedder {

    /// Dimension of the word embedding vectors.
    static let embeddingDimension = 512

    /// LRU embedding cache — avoids re-computing vectors for repeated app names and window titles.
    private static var sentenceCache: [Int: [Double]] = [:]
    private static var cacheOrder: [Int] = []
    private static let maxCacheSize = 512
    private static let cacheLock = NSLock()

    // MARK: - Word Embedding

    /// Get the embedding vector for a single word.
    /// Returns nil if the word is not in the vocabulary.
    static func wordVector(_ word: String, language: NLLanguage = .english) -> [Double]? {
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else { return nil }
        return embedding.vector(for: word)
    }

    /// Get a sentence-level embedding by averaging word vectors.
    /// This is a simple but effective approach for semantic similarity.
    /// Uses LRU cache to avoid re-embedding repeated text (>60% hit rate expected).
    static func sentenceVector(_ text: String, language: NLLanguage = .english) -> [Double]? {
        let cacheKey = text.hashValue

        // Check cache first
        cacheLock.lock()
        if let cached = sentenceCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let embedding = NLEmbedding.wordEmbedding(for: language) else { return nil }

        // Tokenize and get vectors for each word
        let words = text.lowercased().split(separator: " ").map(String.init)
        var vectors: [[Double]] = []

        for word in words {
            if let vector = embedding.vector(for: word) {
                vectors.append(vector)
            }
        }

        guard !vectors.isEmpty else { return nil }

        // Average all word vectors
        let dim = vectors[0].count
        var result = [Double](repeating: 0, count: dim)

        for vector in vectors {
            vDSP_vaddD(result, 1, vector, 1, &result, 1, vDSP_Length(dim))
        }

        var count = Double(vectors.count)
        vDSP_vsdivD(result, 1, &count, &result, 1, vDSP_Length(dim))

        // Store in cache (LRU eviction)
        cacheLock.lock()
        sentenceCache[cacheKey] = result
        cacheOrder.append(cacheKey)
        if sentenceCache.count > maxCacheSize {
            let evict = cacheOrder.removeFirst()
            sentenceCache.removeValue(forKey: evict)
        }
        cacheLock.unlock()

        return result
    }

    // MARK: - Similarity

    /// Cosine similarity between two vectors using Accelerate.
    /// Returns a value between -1.0 (opposite) and 1.0 (identical).
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }

        let n = vDSP_Length(a.count)

        var dotProduct: Double = 0
        vDSP_dotprD(a, 1, b, 1, &dotProduct, n)

        var normA: Double = 0
        vDSP_svesqD(a, 1, &normA, n)

        var normB: Double = 0
        vDSP_svesqD(b, 1, &normB, n)

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0.0 }

        return dotProduct / denominator
    }

    /// Cosine similarity between two Float vectors (for SQLite BLOB storage).
    static func cosineSimilarityFloat(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }

        let n = vDSP_Length(a.count)

        var dotProduct: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, n)

        var normA: Float = 0
        vDSP_svesq(a, 1, &normA, n)

        var normB: Float = 0
        vDSP_svesq(b, 1, &normB, n)

        let denominator = sqrtf(normA) * sqrtf(normB)
        guard denominator > 0 else { return 0.0 }

        return dotProduct / denominator
    }

    // MARK: - Topic Similarity

    /// Compute semantic similarity between two text strings.
    /// Returns 0.0 to 1.0 (higher = more similar).
    static func textSimilarity(_ textA: String, _ textB: String, language: NLLanguage = .english) -> Double {
        guard let vecA = sentenceVector(textA, language: language),
              let vecB = sentenceVector(textB, language: language) else {
            // Fallback to keyword overlap if embeddings unavailable
            return keywordOverlap(textA, textB)
        }

        // Map cosine similarity from [-1, 1] to [0, 1]
        return (cosineSimilarity(vecA, vecB) + 1.0) / 2.0
    }

    /// Jaccard similarity of keyword sets (fallback when embeddings unavailable).
    private static func keywordOverlap(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(separator: " ").map(String.init))
        let wordsB = Set(b.lowercased().split(separator: " ").map(String.init))
        let intersection = wordsA.intersection(wordsB)
        let union = wordsA.union(wordsB)
        guard !union.isEmpty else { return 0 }
        return Double(intersection.count) / Double(union.count)
    }

    // MARK: - Tiled Batch Similarity (Flash Attention IO-Aware)

    /// Compute cosine similarity between a query and multiple candidates using cache-friendly tiling.
    /// Processes candidates in tiles of `tileSize` to keep intermediates in L1/L2 cache,
    /// inspired by Flash Attention's tiled Q*K computation.
    static func tiledBatchSimilarity(
        query: [Double],
        candidates: [[Double]],
        tileSize: Int = 64
    ) -> [(index: Int, similarity: Double)] {
        return FlashAttentionUtils.tiledCosineSimilarity(
            query: query, candidates: candidates, tileSize: tileSize
        )
    }

    /// Batch text similarity using tiled computation for cache efficiency.
    static func tiledTextSimilarity(
        query: String,
        candidates: [String],
        tileSize: Int = 64,
        language: NLLanguage = .english
    ) -> [(index: Int, similarity: Double)] {
        guard let queryVec = sentenceVector(query, language: language) else { return [] }

        let candidateVecs = candidates.compactMap { text -> (Int, [Double])? in
            guard let vec = sentenceVector(text, language: language) else { return nil }
            return (0, vec)  // index set below
        }

        // Build dense candidate matrix
        var indexMap: [Int] = []
        var vectors: [[Double]] = []
        for (i, text) in candidates.enumerated() {
            if let vec = sentenceVector(text, language: language) {
                indexMap.append(i)
                vectors.append(vec)
            }
        }

        let tiledResults = FlashAttentionUtils.tiledCosineSimilarity(
            query: queryVec, candidates: vectors, tileSize: tileSize
        )

        // Map back to original indices
        return tiledResults.map { (indexMap[$0.index], $0.similarity) }
    }

    // MARK: - Adaptive Cache (Flash Attention Recomputation Trade-off)

    /// Access frequency tracker for adaptive caching.
    /// High-frequency embeddings stay cached; rare ones are recomputed on demand.
    private static var accessFrequency: [Int: Int] = [:]
    private static let frequencyThreshold = 3  // Cache only if accessed 3+ times

    /// Get sentence vector with adaptive caching: frequently accessed vectors stay cached,
    /// rare ones are recomputed. Inspired by Flash Attention's recomputation-vs-storage trade-off.
    static func adaptiveSentenceVector(_ text: String, language: NLLanguage = .english) -> [Double]? {
        let cacheKey = text.hashValue

        cacheLock.lock()
        let frequency = accessFrequency[cacheKey, default: 0] + 1
        accessFrequency[cacheKey] = frequency

        // If high frequency, use cache path
        if frequency >= frequencyThreshold, let cached = sentenceCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Compute embedding
        guard let embedding = NLEmbedding.wordEmbedding(for: language) else { return nil }
        let words = text.lowercased().split(separator: " ").map(String.init)
        var vectors: [[Double]] = []

        for word in words {
            if let vector = embedding.vector(for: word) {
                vectors.append(vector)
            }
        }

        guard !vectors.isEmpty else { return nil }
        let dim = vectors[0].count
        var result = [Double](repeating: 0, count: dim)

        for vector in vectors {
            vDSP_vaddD(result, 1, vector, 1, &result, 1, vDSP_Length(dim))
        }
        var count = Double(vectors.count)
        vDSP_vsdivD(result, 1, &count, &result, 1, vDSP_Length(dim))

        // Only cache if accessed frequently enough (recomputation trade-off)
        if frequency >= frequencyThreshold {
            cacheLock.lock()
            sentenceCache[cacheKey] = result
            cacheOrder.append(cacheKey)
            if sentenceCache.count > maxCacheSize {
                let evict = cacheOrder.removeFirst()
                sentenceCache.removeValue(forKey: evict)
                accessFrequency.removeValue(forKey: evict)
            }
            cacheLock.unlock()
        }

        return result
    }

    /// Trim the access frequency tracker to prevent unbounded growth.
    static func trimFrequencyTracker() {
        cacheLock.lock()
        if accessFrequency.count > maxCacheSize * 2 {
            // Keep only keys that are in the cache or have high frequency
            let threshold = frequencyThreshold
            accessFrequency = accessFrequency.filter { sentenceCache[$0.key] != nil || $0.value >= threshold }
        }
        cacheLock.unlock()
    }

    // MARK: - Block Quantization (Flash Attention 3-inspired)

    /// Quantize a sentence embedding for compact storage (~4x reduction).
    /// Uses per-block scale factors (64-dim blocks) for better accuracy than global quantization.
    static func quantize(_ vector: [Double], blockSize: Int = 64) -> FlashAttentionUtils.QuantizedVector {
        FlashAttentionUtils.blockQuantize(vector, blockSize: blockSize)
    }

    /// Compute similarity between a full-precision query and a quantized stored vector.
    static func quantizedSimilarity(query: [Double], quantized: FlashAttentionUtils.QuantizedVector) -> Double {
        FlashAttentionUtils.quantizedCosineSimilarity(query: query, quantized: quantized)
    }

    /// Serialize a quantized vector to Data for SQLite BLOB storage.
    static func serializeQuantized(_ quantized: FlashAttentionUtils.QuantizedVector) -> Data {
        quantized.serialize()
    }

    /// Deserialize a quantized vector from Data.
    static func deserializeQuantized(_ data: Data) -> FlashAttentionUtils.QuantizedVector? {
        FlashAttentionUtils.QuantizedVector.deserialize(data)
    }

    // MARK: - Serialization Helpers

    /// Convert a Double vector to Float array for compact BLOB storage.
    static func toFloatArray(_ doubles: [Double]) -> [Float] {
        var result = [Float](repeating: 0, count: doubles.count)
        vDSP_vdpsp(doubles, 1, &result, 1, vDSP_Length(doubles.count))
        return result
    }

    /// Convert a Float array back to Double vector.
    static func toDoubleArray(_ floats: [Float]) -> [Double] {
        var result = [Double](repeating: 0, count: floats.count)
        vDSP_vspdp(floats, 1, &result, 1, vDSP_Length(floats.count))
        return result
    }

    /// Serialize Float array to Data for SQLite BLOB storage.
    static func serialize(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Deserialize Data back to Float array.
    static func deserialize(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
