import Foundation

/// Human vision-inspired attention stages for progressive context compression.
///
/// Like the retina, each stage trades resolution for coverage:
/// - **Fovea:** Highest acuity (2°) — full detail on the active command
/// - **Parafovea:** Good detail (5°) — compressed follow-up context
/// - **Macula:** Moderate detail (18°) — background evaluation with cheap models
/// - **Near Peripheral:** Low detail (60°) — monitoring with drift gating
/// - **Far Peripheral:** Minimal awareness (>100°) — dormant, zero API, embeddings only
enum AttentionStage: Int, Comparable, CustomStringConvertible {
    case fovea = 1
    case parafovea = 2
    case macula = 3
    case nearPeripheral = 4
    case farPeripheral = 5

    static func < (lhs: AttentionStage, rhs: AttentionStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .fovea: return "fovea"
        case .parafovea: return "parafovea"
        case .macula: return "macula"
        case .nearPeripheral: return "nearPeripheral"
        case .farPeripheral: return "farPeripheral"
        }
    }

    var budget: AttentionBudget {
        switch self {
        case .fovea:
            return AttentionBudget(
                maxSystemPromptTokens: 15_000,
                maxToolResultChars: 8_000,
                maxOutputTokens: 8192,
                maxTools: 40,
                maxHistoryMessages: 8,
                modelTier: .full
            )
        case .parafovea:
            return AttentionBudget(
                maxSystemPromptTokens: 6_000,
                maxToolResultChars: 2_000,
                maxOutputTokens: 2048,
                maxTools: 15,
                maxHistoryMessages: 4,
                modelTier: .full
            )
        case .macula:
            return AttentionBudget(
                maxSystemPromptTokens: 500,
                maxToolResultChars: 0,
                maxOutputTokens: 150,
                maxTools: 0,
                maxHistoryMessages: 0,
                modelTier: .cheap
            )
        case .nearPeripheral:
            return AttentionBudget(
                maxSystemPromptTokens: 800,
                maxToolResultChars: 0,
                maxOutputTokens: 600,
                maxTools: 0,
                maxHistoryMessages: 0,
                modelTier: .local
            )
        case .farPeripheral:
            return AttentionBudget(
                maxSystemPromptTokens: 0,
                maxToolResultChars: 0,
                maxOutputTokens: 0,
                maxTools: 0,
                maxHistoryMessages: 0,
                modelTier: .none
            )
        }
    }
}

/// Token and resource budget for a given attention stage.
struct AttentionBudget {
    let maxSystemPromptTokens: Int
    let maxToolResultChars: Int
    let maxOutputTokens: Int
    let maxTools: Int
    let maxHistoryMessages: Int
    let modelTier: ModelTier

    /// Whether this stage allows LLM API calls at all.
    var allowsAPICall: Bool { modelTier != .none }
}

/// Model tier selection per attention stage.
enum ModelTier: Int, Comparable {
    case full = 1    // Current provider (Claude/DeepSeek/Gemini)
    case cheap = 2   // Cheapest available (DeepSeek-chat)
    case local = 3   // On-device only (NeuralCompute, MLX, NLEmbedding)
    case none = 4    // No model — pure embedding operations

    static func < (lhs: ModelTier, rhs: ModelTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
