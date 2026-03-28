import Foundation

/// Links related activities across different applications.
/// Detects patterns like: copy in Safari → paste in TextEdit.
enum CrossAppCorrelator {

    /// Check if two observations from different apps are related.
    static func areRelated(_ a: SemanticObservation, _ b: SemanticObservation) -> Bool {
        guard a.appName != b.appName else { return true }

        // Check topic overlap
        let topicsA = Set(a.relatedTopics)
        let topicsB = Set(b.relatedTopics)
        let intersection = topicsA.intersection(topicsB)
        let union = topicsA.union(topicsB)

        guard !union.isEmpty else { return false }
        let jaccard = Double(intersection.count) / Double(union.count)

        return jaccard >= 0.2
    }

    /// Check if two observations are within a reasonable time window for correlation.
    static func areTemporallyClose(_ a: SemanticObservation, _ b: SemanticObservation, windowSeconds: TimeInterval = 300) -> Bool {
        abs(a.timestamp.timeIntervalSince(b.timestamp)) < windowSeconds
    }
}
