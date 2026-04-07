import Foundation

/// Central routing logic that assigns an attention stage to each processing context.
///
/// Maps the caller's intent to the appropriate foveal attention stage:
/// - User commands → Fovea (Stage 1)
/// - Follow-ups → Parafovea (Stage 2), promoted to Fovea if complex
/// - Background evaluation → Macula (Stage 3)
/// - Periodic synthesis/learning → Near Peripheral (Stage 4)
/// - Dormant context scanning → Far Peripheral (Stage 5)
enum FovealRouter {

    /// Determine the attention stage for a user-initiated command.
    static func stageForUserCommand(isFollowUp: Bool, command: String) -> AttentionStage {
        guard isFollowUp else { return .fovea }

        // Follow-up promotion: complex/deep follow-ups get full foveal attention
        let complexity = AgentLoop.classifyComplexity(command)
        switch complexity {
        case .complex, .deep:
            print("[FovealRouter] Follow-up promoted to fovea (complexity: \(complexity))")
            return .fovea
        case .simple, .medium:
            return .parafovea
        }
    }

    /// Stage for coworking suggestion evaluation.
    static var stageForCoworking: AttentionStage { .macula }

    /// Stage for security risk assessment.
    static var stageForSecurityRisk: AttentionStage { .macula }

    /// Stage for synthesis engine.
    static var stageForSynthesis: AttentionStage { .nearPeripheral }

    /// Stage for learning feedback loop rule generation.
    static var stageForLearningRules: AttentionStage { .nearPeripheral }

    /// Stage for goal subgoal generation.
    static var stageForGoalGeneration: AttentionStage { .nearPeripheral }

    /// Stage for dormant context (old memories, stale goals, unused skills).
    static var stageForDormantContext: AttentionStage { .farPeripheral }

    // MARK: - Budget Helpers

    /// Get the token budget for tool results at a given stage.
    static func toolResultLimit(for toolName: String, stage: AttentionStage) -> Int {
        stage.budget.maxToolResultChars
    }

    /// Get the max number of tools to include in the schema.
    static func maxTools(for stage: AttentionStage) -> Int {
        stage.budget.maxTools
    }

    /// Get the max output tokens for LLM response.
    static func maxOutputTokens(for stage: AttentionStage) -> Int {
        stage.budget.maxOutputTokens
    }

    // MARK: - Drift Detection (Stage 4 Gate)

    /// Check if the context has drifted enough to warrant an API call.
    /// Returns true if the LLM call should proceed, false if context hasn't changed enough.
    static func shouldCallAPI(
        currentSnapshot: String,
        previousEmbedding: inout [Double]?,
        driftThreshold: Double = 0.7
    ) -> Bool {
        guard let currentVec = TextEmbedder.sentenceVector(currentSnapshot) else {
            // Can't compute embedding — allow the call
            return true
        }

        if let prevVec = previousEmbedding {
            let similarity = TextEmbedder.cosineSimilarity(currentVec, prevVec)
            if similarity > driftThreshold {
                print("[FovealRouter] Drift gate: similarity \(String(format: "%.3f", similarity)) > \(driftThreshold), skipping API call")
                return false
            }
            print("[FovealRouter] Drift gate: similarity \(String(format: "%.3f", similarity)) <= \(driftThreshold), allowing API call")
        }

        // Update the previous embedding
        previousEmbedding = currentVec
        return true
    }
}
