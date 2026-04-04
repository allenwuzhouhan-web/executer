import Foundation
import Vision
import CoreGraphics

/// Thin wrapper around Apple Vision for in-memory OCR.
/// Unlike OCRImageTool (which reads files), this works on in-memory CGImages.
enum OCRService {

    struct OCRResult {
        let text: String
        /// Bounding box in normalized coordinates (0-1), origin bottom-left.
        let boundingBox: CGRect
        let confidence: Float
    }

    /// Recognize text in an entire CGImage.
    static func recognize(image: CGImage, languages: [String] = ["en"]) async throws -> [OCRResult] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let results = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation -> OCRResult? in
                    guard let topCandidate = observation.topCandidates(1).first else { return nil }
                    return OCRResult(
                        text: topCandidate.string,
                        boundingBox: observation.boundingBox,
                        confidence: topCandidate.confidence
                    )
                }
                continuation.resume(returning: results)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Recognize text in a specific region of an image.
    /// Region is in normalized coordinates (0-1), origin bottom-left.
    static func recognizeInRegion(image: CGImage, region: CGRect) async throws -> [OCRResult] {
        let results = try await recognize(image: image)
        return results.filter { region.intersects($0.boundingBox) }
    }

    /// Convert a normalized bounding box (origin bottom-left) to screen coordinates (origin top-left).
    static func toScreenCoordinates(_ box: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let x = box.origin.x * CGFloat(imageWidth)
        let y = (1.0 - box.origin.y - box.height) * CGFloat(imageHeight)
        let w = box.width * CGFloat(imageWidth)
        let h = box.height * CGFloat(imageHeight)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
