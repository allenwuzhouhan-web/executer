import Foundation

enum InputBarState: Equatable {
    case idle
    case ready
    case processing
    case planning(summary: String)
    case executing(toolName: String, step: Int, total: Int)
    case streaming(partialText: String)
    case result(message: String, trace: AgentTrace? = nil)
    case richResult(result: RichResult, rawMessage: String, trace: AgentTrace? = nil)
    case error(message: String, trace: AgentTrace? = nil)
    case researchChoice(query: String)
    case browserChoice(query: String)
    case thoughtRecall(ThoughtRecall)
    case healthCard(message: String)
    case voiceListening(partial: String)
    case newsBriefing(articles: [NewsBriefingArticle])
    case coworkingSuggestion(CoworkingSuggestion)

    // Equatable conformance for RichResult
    static func == (lhs: InputBarState, rhs: InputBarState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.ready, .ready), (.processing, .processing): return true
        case (.planning(let a), .planning(let b)): return a == b
        case (.executing(let a1, let a2, let a3), .executing(let b1, let b2, let b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case (.streaming(let a), .streaming(let b)): return a == b
        case (.result(let a, let at), .result(let b, let bt)): return a == b && at?.id == bt?.id
        case (.richResult(_, let a, let at), .richResult(_, let b, let bt)): return a == b && at?.id == bt?.id
        case (.error(let a, let at), .error(let b, let bt)): return a == b && at?.id == bt?.id
        case (.researchChoice(let a), .researchChoice(let b)): return a == b
        case (.browserChoice(let a), .browserChoice(let b)): return a == b
        case (.thoughtRecall(let a), .thoughtRecall(let b)): return a == b
        case (.healthCard(let a), .healthCard(let b)): return a == b
        case (.voiceListening(let a), .voiceListening(let b)): return a == b
        case (.newsBriefing(let a), .newsBriefing(let b)): return a == b
        case (.coworkingSuggestion(let a), .coworkingSuggestion(let b)): return a.id == b.id
        default: return false
        }
    }
}
