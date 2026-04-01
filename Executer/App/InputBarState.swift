import Foundation

enum InputBarState: Equatable {
    case idle
    case ready
    case processing
    case planning(summary: String)
    case executing(toolName: String, step: Int, total: Int)
    case streaming(partialText: String)
    case result(message: String)
    case richResult(result: RichResult, rawMessage: String)
    case error(message: String)
    case researchChoice(query: String)
    case browserChoice(query: String)
    case thoughtRecall(ThoughtRecall)
    case healthCard(message: String)
    case voiceListening(partial: String)
    case newsBriefing(articles: [NewsBriefingArticle])

    // Equatable conformance for RichResult
    static func == (lhs: InputBarState, rhs: InputBarState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.ready, .ready), (.processing, .processing): return true
        case (.planning(let a), .planning(let b)): return a == b
        case (.executing(let a1, let a2, let a3), .executing(let b1, let b2, let b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case (.streaming(let a), .streaming(let b)): return a == b
        case (.result(let a), .result(let b)): return a == b
        case (.richResult(_, let a), .richResult(_, let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        case (.researchChoice(let a), .researchChoice(let b)): return a == b
        case (.browserChoice(let a), .browserChoice(let b)): return a == b
        case (.thoughtRecall(let a), .thoughtRecall(let b)): return a == b
        case (.healthCard(let a), .healthCard(let b)): return a == b
        case (.voiceListening(let a), .voiceListening(let b)): return a == b
        case (.newsBriefing(let a), .newsBriefing(let b)): return a == b
        default: return false
        }
    }
}
