import Foundation

/// A higher-order insight produced by correlating real-time observations across multiple apps.
/// Complements `SynthesisInsight` (deep, LLM-based, hourly) with real-time stream correlation.
struct CrossAppInsight: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let type: InsightType
    let title: String                    // "Preparing for strategy meeting"
    let summary: String                  // 2-3 sentence synthesis
    let sources: [InsightSource]         // What observations contributed
    let connectedApps: [String]          // Apps involved
    let connectedTopics: [String]        // Unified topic set
    let confidence: Double               // 0.0-1.0
    let actionability: Actionability     // How the user can act on this

    enum InsightType: String, Codable, Sendable {
        case crossAppFusion              // Real-time: linking concurrent activity
        case researchAggregation         // Correlating findings from multiple sources
        case projectRollup               // Summarizing multi-session project state
    }

    struct InsightSource: Codable, Sendable {
        let appName: String
        let observationType: String      // "browsing", "editing", "communicating"
        let snippet: String              // Brief description of what was observed
        let timestamp: Date
    }

    enum Actionability: String, Codable, Sendable {
        case informational               // Just context for the LLM
        case suggestAction               // "Want me to compile these findings?"
        case urgent                      // "Conflicting data — review needed"
    }

    /// Short prompt-friendly summary for LLM context injection.
    var promptLine: String {
        let apps = connectedApps.joined(separator: " + ")
        return "[\(type.rawValue)] \(title) (\(apps)) — \(summary)"
    }
}
