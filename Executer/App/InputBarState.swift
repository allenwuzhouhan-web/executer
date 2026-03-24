import Foundation

enum InputBarState: Equatable {
    case idle
    case ready
    case processing
    case planning(summary: String)
    case executing(toolName: String, step: Int, total: Int)
    case streaming(partialText: String)
    case result(message: String)
    case error(message: String)
    case researchChoice(query: String)
    case thoughtRecall(ThoughtRecall)
    case healthCard(message: String)
    case voiceListening(partial: String)
}
