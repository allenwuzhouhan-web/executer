import Foundation
import Accelerate

/// Flash Attention-inspired algorithms adapted for on-device attention processing.
/// Implements IO-aware, numerically stable streaming operations from the Flash Attention papers.
enum FlashAttentionUtils {

    // MARK: - Online Softmax (Flash Attention Core)

    /// State for incremental softmax computation across blocks.
    /// Maintains running max and normalizer so we never need the full score array in memory.
    struct OnlineSoftmaxState {
        var runningMax: Double = -.infinity
        var runningSum: Double = 0.0
        var count: Int = 0

        /// Feed a new block of scores and return the current normalized weights for this block.
        /// Uses the Milakov & Gimelshein (2018) online algorithm from Flash Attention.
        mutating func feed(scores: [Double]) -> [Double] {
            guard !scores.isEmpty else { return [] }

            let blockMax = scores.max()!
            let prevMax = runningMax

            // Update running max
            runningMax = max(runningMax, blockMax)

            // Rescale previous running sum to new max
            if prevMax > -.infinity {
                runningSum *= exp(prevMax - runningMax)
            }

            // Compute exponentials for this block under new max
            var weights = scores.map { exp($0 - runningMax) }
            let blockSum = weights.reduce(0.0, +)
            runningSum += blockSum
            count += scores.count

            return weights
        }

        /// Normalize a set of raw weights (from `feed`) against the final running sum.
        func normalize(_ rawWeights: [Double]) -> [Double] {
            guard runningSum > 0 else { return rawWeights.map { _ in 0.0 } }
            return rawWeights.map { $0 / runningSum }
        }

        /// Normalize weights that were computed under an older max value.
        func normalizeRescaled(_ rawWeights: [Double], computedUnderMax oldMax: Double) -> [Double] {
            guard runningSum > 0 else { return rawWeights.map { _ in 0.0 } }
            let rescale = exp(oldMax - runningMax)
            return rawWeights.map { ($0 * rescale) / runningSum }
        }
    }

    /// Score and rank items in a streaming fashion using online softmax.
    /// Returns indices sorted by descending normalized probability.
    static func streamingSoftmaxRank(scores: [Double], blockSize: Int = 32) -> [(index: Int, probability: Double)] {
        guard !scores.isEmpty else { return [] }

        var state = OnlineSoftmaxState()
        var allRawWeights: [(blockIndex: Int, weights: [Double], maxAtCompute: Double)] = []

        // Process scores in blocks
        var offset = 0
        while offset < scores.count {
            let end = min(offset + blockSize, scores.count)
            let block = Array(scores[offset..<end])
            let maxBefore = state.runningMax
            let raw = state.feed(scores: block)
            allRawWeights.append((offset, raw, state.runningMax))
            _ = maxBefore  // recorded for rescaling
            offset = end
        }

        // Final normalization pass — rescale all blocks to final max
        var results: [(index: Int, probability: Double)] = []
        results.reserveCapacity(scores.count)

        for (blockOffset, weights, blockMax) in allRawWeights {
            let normalized = state.normalizeRescaled(weights, computedUnderMax: blockMax)
            for (i, prob) in normalized.enumerated() {
                results.append((blockOffset + i, prob))
            }
        }

        return results.sorted { $0.probability > $1.probability }
    }

    // MARK: - Softcapping (Flash Attention 3)

    /// Apply softcap to bound scores: softcap * tanh(score / softcap).
    /// Prevents any single signal from dominating when combining multiple sources.
    static func softcap(_ score: Double, cap: Double = 50.0) -> Double {
        cap * tanh(score / cap)
    }

    /// Vectorized softcap for arrays using Accelerate.
    static func softcapArray(_ scores: inout [Double], cap: Double = 50.0) {
        let n = scores.count
        guard n > 0 else { return }

        // scores / cap
        var invCap = 1.0 / cap
        vDSP_vsmulD(scores, 1, &invCap, &scores, 1, vDSP_Length(n))

        // tanh(scores / cap)
        var count = Int32(n)
        vvtanh(&scores, scores, &count)

        // cap * tanh(scores / cap)
        var capVal = cap
        vDSP_vsmulD(scores, 1, &capVal, &scores, 1, vDSP_Length(n))
    }

    // MARK: - Tiled Similarity (IO-Aware Blocking)

    /// Compute cosine similarity between a query vector and a matrix of candidates,
    /// processing in cache-friendly tiles to minimize memory bandwidth.
    /// Returns (index, similarity) pairs sorted by descending similarity.
    static func tiledCosineSimilarity(
        query: [Double],
        candidates: [[Double]],
        tileSize: Int = 64
    ) -> [(index: Int, similarity: Double)] {
        guard !candidates.isEmpty, !query.isEmpty else { return [] }

        let dim = query.count
        let n = vDSP_Length(dim)

        // Pre-compute query norm once
        var queryNormSq: Double = 0
        vDSP_svesqD(query, 1, &queryNormSq, n)
        let queryNorm = sqrt(queryNormSq)
        guard queryNorm > 0 else { return [] }

        var results: [(index: Int, similarity: Double)] = []
        results.reserveCapacity(candidates.count)

        // Process in tiles for cache locality
        var tileStart = 0
        while tileStart < candidates.count {
            let tileEnd = min(tileStart + tileSize, candidates.count)

            for i in tileStart..<tileEnd {
                let candidate = candidates[i]
                guard candidate.count == dim else {
                    results.append((i, 0.0))
                    continue
                }

                var dot: Double = 0
                vDSP_dotprD(query, 1, candidate, 1, &dot, n)

                var candNormSq: Double = 0
                vDSP_svesqD(candidate, 1, &candNormSq, n)
                let candNorm = sqrt(candNormSq)

                let similarity = candNorm > 0 ? dot / (queryNorm * candNorm) : 0.0
                results.append((i, similarity))
            }

            tileStart = tileEnd
        }

        return results.sorted { $0.similarity > $1.similarity }
    }

    // MARK: - Block Quantization (Flash Attention 3)

    /// Quantize a Double vector to Int8 with per-block scale factors.
    /// Each block of `blockSize` dimensions gets its own scale factor,
    /// reducing quantization error compared to per-tensor quantization.
    struct QuantizedVector {
        let values: [Int8]
        let scaleFactors: [Float]  // One per block
        let blockSize: Int
        let originalDimension: Int

        /// Serialize to compact Data for storage (~5x smaller than [Float]).
        func serialize() -> Data {
            var data = Data()

            // Header: dimension (4 bytes) + blockSize (4 bytes)
            var dim = Int32(originalDimension)
            var bs = Int32(blockSize)
            data.append(Data(bytes: &dim, count: 4))
            data.append(Data(bytes: &bs, count: 4))

            // Scale factors
            scaleFactors.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }

            // Quantized values
            values.withUnsafeBufferPointer {
                data.append(Data(bytes: $0.baseAddress!, count: $0.count))
            }

            return data
        }

        /// Deserialize from Data.
        static func deserialize(_ data: Data) -> QuantizedVector? {
            guard data.count >= 8 else { return nil }

            let dim = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) }
            let bs = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
            let blockSize = Int(bs)
            let dimension = Int(dim)

            let numBlocks = (dimension + blockSize - 1) / blockSize
            let scaleStart = 8
            let scaleEnd = scaleStart + numBlocks * MemoryLayout<Float>.size
            guard data.count >= scaleEnd + dimension else { return nil }

            let scales: [Float] = data[scaleStart..<scaleEnd].withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }

            let values: [Int8] = data[scaleEnd..<(scaleEnd + dimension)].withUnsafeBytes {
                Array($0.bindMemory(to: Int8.self))
            }

            return QuantizedVector(
                values: values,
                scaleFactors: scales,
                blockSize: blockSize,
                originalDimension: dimension
            )
        }

        /// Dequantize back to Double vector.
        func dequantize() -> [Double] {
            var result = [Double](repeating: 0, count: originalDimension)
            for blockIdx in 0..<scaleFactors.count {
                let start = blockIdx * blockSize
                let end = min(start + blockSize, originalDimension)
                let scale = Double(scaleFactors[blockIdx])
                for i in start..<end {
                    result[i] = Double(values[i]) * scale
                }
            }
            return result
        }
    }

    /// Quantize a Double vector using per-block Int8 quantization.
    static func blockQuantize(_ vector: [Double], blockSize: Int = 64) -> QuantizedVector {
        let dim = vector.count
        let numBlocks = (dim + blockSize - 1) / blockSize
        var quantized = [Int8](repeating: 0, count: dim)
        var scales = [Float](repeating: 0, count: numBlocks)

        for blockIdx in 0..<numBlocks {
            let start = blockIdx * blockSize
            let end = min(start + blockSize, dim)

            // Find max absolute value in block
            var maxAbs: Double = 0
            for i in start..<end {
                maxAbs = max(maxAbs, abs(vector[i]))
            }

            // Scale factor: map [-maxAbs, maxAbs] to [-127, 127]
            let scale = maxAbs > 0 ? maxAbs / 127.0 : 1.0
            scales[blockIdx] = Float(scale)

            // Quantize
            for i in start..<end {
                let q = vector[i] / scale
                quantized[i] = Int8(max(-127, min(127, Int(q.rounded()))))
            }
        }

        return QuantizedVector(
            values: quantized,
            scaleFactors: scales,
            blockSize: blockSize,
            originalDimension: dim
        )
    }

    /// Compute approximate cosine similarity between a full-precision query and a quantized vector.
    /// Avoids full dequantization by computing block-wise dot products.
    static func quantizedCosineSimilarity(query: [Double], quantized: QuantizedVector) -> Double {
        guard query.count == quantized.originalDimension else { return 0.0 }

        var dot = 0.0
        var queryNormSq = 0.0
        var quantNormSq = 0.0

        for blockIdx in 0..<quantized.scaleFactors.count {
            let start = blockIdx * quantized.blockSize
            let end = min(start + quantized.blockSize, quantized.originalDimension)
            let scale = Double(quantized.scaleFactors[blockIdx])

            for i in start..<end {
                let qVal = query[i]
                let dVal = Double(quantized.values[i]) * scale
                dot += qVal * dVal
                queryNormSq += qVal * qVal
                quantNormSq += dVal * dVal
            }
        }

        let denom = sqrt(queryNormSq) * sqrt(quantNormSq)
        return denom > 0 ? dot / denom : 0.0
    }

    // MARK: - Causal Mask

    /// Check if action at position `queryPos` can attend to action at position `keyPos`,
    /// respecting causal ordering and session boundaries.
    static func causalMaskAllows(
        queryPos: Int,
        keyPos: Int,
        sessionBoundaries: Set<Int>
    ) -> Bool {
        // Causal: can only attend to past (key <= query)
        guard keyPos <= queryPos else { return false }

        // Check for session boundary between key and query
        for boundary in sessionBoundaries {
            if boundary > keyPos && boundary <= queryPos {
                return false  // Session boundary blocks attention
            }
        }

        return true
    }

    // MARK: - Sliding Window

    /// Compute attention weights with a sliding window constraint.
    /// Only positions within [queryPos - windowSize, queryPos] contribute.
    static func slidingWindowWeights(
        scores: [Double],
        queryPosition: Int,
        windowSize: Int,
        decayFactor: Double = 0.95
    ) -> [Double] {
        var weights = [Double](repeating: 0, count: scores.count)

        for i in 0..<scores.count {
            let distance = queryPosition - i
            if distance >= 0 && distance <= windowSize {
                // Exponential decay within window
                weights[i] = scores[i] * pow(decayFactor, Double(distance))
            }
            // Outside window: weight stays 0
        }

        // Normalize
        let total = weights.reduce(0.0, +)
        if total > 0 {
            for i in weights.indices {
                weights[i] /= total
            }
        }

        return weights
    }

    // MARK: - IO-Aware Buffer

    /// Pre-allocated contiguous buffer for building string context efficiently.
    /// Avoids repeated String concatenation which causes O(n^2) copying.
    class ContextBuffer {
        private var segments: [String] = []
        private var totalLength: Int = 0

        init(estimatedSegments: Int = 16) {
            segments.reserveCapacity(estimatedSegments)
        }

        func append(_ text: String) {
            guard !text.isEmpty else { return }
            segments.append(text)
            totalLength += text.count
        }

        func append(_ text: String, separator: String) {
            if !segments.isEmpty {
                segments.append(separator)
                totalLength += separator.count
            }
            segments.append(text)
            totalLength += text.count
        }

        var estimatedLength: Int { totalLength }

        /// Materialize to a single String in one pass.
        func build() -> String {
            var result = ""
            result.reserveCapacity(totalLength)
            for segment in segments {
                result += segment
            }
            return result
        }

        func reset() {
            segments.removeAll(keepingCapacity: true)
            totalLength = 0
        }
    }
}
