import Foundation

/// Extracts semantic observations from communication apps (Mail, Slack, Teams, WeChat).
/// PRIVACY: Only captures participant names and channels — NEVER message body text.
struct CommunicationExtractor: AttentionExtractor {
    var appPatterns: [String] { ["mail", "outlook", "slack", "teams", "discord", "telegram", "wechat", "messages", "imessage", "zoom", "signal", "whatsapp"] }

    func extract(actions: [UserAction], screenText: [String]?, appName: String) -> [SemanticObservation] {
        var details: [String: String] = [:]
        var participants: [String] = []

        // Extract channel/contact names from UI elements (NOT message bodies)
        for action in actions {
            let role = action.elementRole
            let title = action.elementTitle

            // Channel names, contact names, subject lines (from UI chrome, not body)
            if (role == "AXStaticText" || role == "AXCell" || role == "AXRow") && !title.isEmpty {
                let entities = NLPipeline.extractEntities(from: title)
                for (value, tag) in entities where tag == .personalName {
                    if !participants.contains(value) {
                        participants.append(value)
                    }
                }
            }
        }

        // Extract channel/recipient from window title
        for action in actions where action.type == .windowOpen || action.type == .focus {
            if !action.elementTitle.isEmpty {
                details["channel"] = action.elementTitle
            }
        }

        if !participants.isEmpty {
            details["participants"] = participants.prefix(5).joined(separator: ", ")
        }

        guard !details.isEmpty else { return [] }

        let intent = "Communicating via \(appName)" + (participants.isEmpty ? "" : " with \(participants.prefix(2).joined(separator: ", "))")

        return [SemanticObservation(
            appName: appName,
            category: .communication,
            intent: intent,
            details: details,
            relatedTopics: participants,
            confidence: 0.5
        )]
    }
}
