import SwiftUI

/// Router view that dispatches RichResult types to their specialized cards.
/// Falls back to ResultBubbleView for plain text.
struct RichResultView: View {
    let result: RichResult
    let rawMessage: String
    let onDismiss: () -> Void

    var body: some View {
        switch result {
        case .text(let message):
            ResultBubbleView(message: message, isError: false, onDismiss: onDismiss)

        case .date(let dateResult):
            DateResultCard(result: dateResult, rawMessage: rawMessage, onDismiss: onDismiss)

        case .event(let eventResult):
            EventResultCard(result: eventResult, rawMessage: rawMessage, onDismiss: onDismiss)

        case .news(let headlines):
            NewsResultCard(headlines: headlines, onDismiss: onDismiss)

        case .list(let title, let items):
            ListResultCard(title: title, items: items, rawMessage: rawMessage, onDismiss: onDismiss)
        }
    }
}
