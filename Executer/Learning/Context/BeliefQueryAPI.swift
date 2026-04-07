import Foundation
import AppKit

/// The interface between the learning engine and the rest of The Executer.
/// The AI layer queries this to understand the user. All queries are confidence-aware.
///
/// Principle 6: only act on beliefs with confidence >= 0.7.
/// Principle 7: never return vetoed beliefs.
actor BeliefQueryAPI {
    static let shared = BeliefQueryAPI()

    // MARK: - Direct Queries

    /// "What apps does Allen use regularly?"
    func getRegularApps() -> [AppUsagePattern] {
        let beliefs = BeliefStore.shared.query(type: .appUsage, minConfidence: 0.7)
        return beliefs.compactMap { decodePattern(AppUsagePattern.self, from: $0.patternData) }
    }

    /// "What is Allen probably working on right now?"
    /// Matches current frontmost app + recent activity against known project clusters.
    func getCurrentProjectContext() -> ProjectContext? {
        let currentApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let projectBeliefs = BeliefStore.shared.query(type: .project, minConfidence: 0.5)

        for belief in projectBeliefs {
            guard let pattern = decodePattern(ProjectClusterPattern.self, from: belief.patternData) else { continue }
            if pattern.apps.contains(currentApp) {
                return ProjectContext(
                    projectName: pattern.clusterName,
                    apps: pattern.apps,
                    domains: pattern.domains,
                    confidence: belief.confidence
                )
            }
        }
        return nil
    }

    /// "What does Allen usually do at this time on this day?"
    func getExpectedRoutine(hour: Int, dayOfWeek: Int) -> RoutineExpectation? {
        let routineBeliefs = BeliefStore.shared.query(type: .routine, minConfidence: 0.7)
        let hourBlock = hour / 2 * 2

        for belief in routineBeliefs {
            guard let pattern = decodePattern(TemporalRoutinePattern.self, from: belief.patternData) else { continue }
            if pattern.hourStart == hourBlock && pattern.daysOfWeek.contains(dayOfWeek) {
                return RoutineExpectation(
                    description: pattern.dominantActivity,
                    dominantApp: pattern.dominantApp,
                    confidence: belief.confidence
                )
            }
        }
        return nil
    }

    /// "Who does Allen message on WeChat vs iMessage?"
    func getCommunicationPatterns() -> [CommunicationPattern] {
        let beliefs = BeliefStore.shared.query(type: .communication, minConfidence: 0.7)
        return beliefs.compactMap { decodePattern(CommunicationPattern.self, from: $0.patternData) }
    }

    /// "What workflow is Allen in the middle of?"
    /// Matches recent transitions against known workflow sequences.
    func detectActiveWorkflow() -> (pattern: WorkflowSequencePattern, confidence: Double)? {
        let workflowBeliefs = BeliefStore.shared.query(type: .workflow, minConfidence: 0.7)
        let currentApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        for belief in workflowBeliefs {
            guard let pattern = decodePattern(WorkflowSequencePattern.self, from: belief.patternData) else { continue }
            // Check if user is at any step in this workflow
            if pattern.steps.contains(where: { $0.app == currentApp }) {
                return (pattern, belief.confidence)
            }
        }
        return nil
    }

    /// "Is Allen stuck?" — repeated searches, same file for >30 min, slowing activity.
    func detectStuckState() -> StuckAssessment {
        // Check recent activity events for signs of being stuck
        let recentActivity = ObservationStore.shared.fetchForDay(
            BeliefStore.dayDateFormatter.string(from: Date()),
            type: .activity
        )

        // Look for patterns: many idle/passive windows in a row
        let recentModes = recentActivity.suffix(6).compactMap { (json, _, _) -> InteractionMode? in
            guard let data = json.data(using: .utf8),
                  let e = try? JSONDecoder().decode(OEActivityEvent.self, from: data) else { return nil }
            return e.interactionMode
        }

        let passiveCount = recentModes.filter { $0 == .passive || $0 == .idle }.count
        let isStuck = passiveCount >= 4 && recentModes.count >= 5

        return StuckAssessment(
            isStuck: isStuck,
            confidence: isStuck ? Double(passiveCount) / Double(max(recentModes.count, 1)) : 0.0,
            evidence: isStuck ? "Low activity for \(passiveCount * 30)+ seconds" : ""
        )
    }

    /// "What are Allen's active projects?"
    func getActiveProjects() -> [ProjectClusterPattern] {
        let beliefs = BeliefStore.shared.query(type: .project, minConfidence: 0.5)
        return beliefs.compactMap { decodePattern(ProjectClusterPattern.self, from: $0.patternData) }
    }

    /// "What does Allen prefer?"
    func getPreferences() -> [PreferencePattern] {
        let beliefs = BeliefStore.shared.query(type: .preference, minConfidence: 0.7)
        return beliefs.compactMap { decodePattern(PreferencePattern.self, from: $0.patternData) }
    }

    // MARK: - Confidence-Aware Queries

    /// Returns only beliefs above the given confidence threshold.
    func query(type: PatternType, minConfidence: Double = 0.7) -> [Belief] {
        BeliefStore.shared.query(type: type, minConfidence: minConfidence)
    }

    /// Returns what The Executer is uncertain about (hypotheses).
    func getUncertainBeliefs() -> [Belief] {
        BeliefStore.shared.hypotheses()
    }

    // MARK: - User Corrections (Principle 7)

    /// User says "that's not a pattern" → permanently suppress.
    func vetoBelief(id: Int, userStatement: String) {
        BeliefStore.shared.vetoBelief(id: id, userStatement: userStatement)
    }

    /// User says "yes, I always do that" → confidence = 1.0 immediately.
    func boostBelief(id: Int, userStatement: String) {
        BeliefStore.shared.boostBelief(id: id, userStatement: userStatement)
    }

    /// User asks "what do you know about me?"
    func getAllKnowledge() -> UserKnowledgeReport {
        let all = BeliefStore.shared.allBeliefs()
        let beliefs = all.filter { $0.classification == .belief && !$0.vetoed }
        let hypotheses = all.filter { $0.classification == .hypothesis && !$0.vetoed }
        let totalObs = ObservationStore.shared.totalCount()
        let days = ObservationStore.shared.distinctDays(recentDays: 365)

        return UserKnowledgeReport(
            beliefs: beliefs,
            hypotheses: hypotheses,
            totalObservations: totalObs,
            oldestObservation: days.first,
            newestObservation: days.last
        )
    }

    /// User says "forget everything about [topic]"
    func forgetTopic(_ topic: String) -> Int {
        BeliefStore.shared.forgetTopic(topic)
    }

    /// User says "stop watching [app]"
    func blacklistApp(bundleId: String) {
        PrivacyGuard.shared.addToUserBlacklist(bundleId: bundleId)
    }

    // MARK: - Helpers

    private func decodePattern<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
