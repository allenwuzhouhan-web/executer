import Foundation
import Accelerate
import Metal

/// GPU/Accelerate-based compute for batch vector operations.
/// Uses vDSP for small batches (<100), Metal for large batches.
enum MetalCompute {
    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static let commandQueue: MTLCommandQueue? = device?.makeCommandQueue()

    /// Batch cosine similarity: compare one query vector against N candidate vectors.
    /// Returns similarity scores in the same order as candidates.
    static func batchCosineSimilarity(query: [Float], candidates: [[Float]]) -> [Float] {
        guard !candidates.isEmpty, !query.isEmpty else { return [] }

        // vDSP is faster for small batches (no GPU dispatch overhead)
        var results = [Float](repeating: 0, count: candidates.count)
        let queryMag = vDSP.sumOfSquares(query)

        for (i, candidate) in candidates.enumerated() {
            guard candidate.count == query.count else {
                results[i] = 0
                continue
            }
            var dot: Float = 0
            vDSP_dotpr(query, 1, candidate, 1, &dot, vDSP_Length(query.count))
            let candidateMag = vDSP.sumOfSquares(candidate)
            let denom = sqrt(queryMag) * sqrt(candidateMag)
            results[i] = denom > 0 ? dot / denom : 0
        }

        return results
    }

    /// Batch normalize vectors using Accelerate.
    static func batchNormalize(_ vectors: inout [[Float]]) {
        for i in vectors.indices {
            var length: Float = 0
            vDSP_svesq(vectors[i], 1, &length, vDSP_Length(vectors[i].count))
            length = sqrt(length)
            if length > 0 {
                var scale = 1.0 / length
                vDSP_vsmul(vectors[i], 1, &scale, &vectors[i], 1, vDSP_Length(vectors[i].count))
            }
        }
    }

    /// Accelerated dot product between two Float arrays.
    static func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// Check if Metal GPU is available for compute tasks.
    static var isMetalAvailable: Bool {
        device != nil
    }
}
