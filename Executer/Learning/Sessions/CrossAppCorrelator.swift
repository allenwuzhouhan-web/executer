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

    /// Group N observations into clusters where members are temporally close and topic-related.
    /// Upgrades pairwise `areRelated` to work over a set via single-linkage clustering.
    static func findClusters(_ observations: [SemanticObservation], windowSeconds: TimeInterval = 300) -> [[SemanticObservation]] {
        guard !observations.isEmpty else { return [] }

        // Union-Find for single-linkage clustering
        var parent = Array(0..<observations.count)

        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]  // path compression
                i = parent[i]
            }
            return i
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Compare all pairs — O(n²) but n is small (sliding window)
        for i in 0..<observations.count {
            for j in (i + 1)..<observations.count {
                if areTemporallyClose(observations[i], observations[j], windowSeconds: windowSeconds) &&
                   areRelated(observations[i], observations[j]) {
                    union(i, j)
                }
            }
        }

        // Group by root
        var groups: [Int: [SemanticObservation]] = [:]
        for i in 0..<observations.count {
            let root = find(i)
            groups[root, default: []].append(observations[i])
        }

        // Return clusters with 2+ members, sorted by size descending
        return groups.values
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }
    }
}
