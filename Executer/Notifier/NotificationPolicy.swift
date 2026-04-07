import Foundation

/// Rules engine for notification routing: urgency thresholds, quiet hours, batching.
enum NotificationPolicy {

    enum Channel: String {
        case immediate      // System notification now
        case nextInteraction // CoworkerAgent suggestion card
        case batch          // Queue for morning console
        case suppress       // Don't deliver at all
    }

    /// Determine the delivery channel based on urgency, time, and user state.
    static func route(urgency: Double, currentHour: Int, isDND: Bool, isDeepWork: Bool) -> Channel {
        // Quiet hours: 11 PM–7 AM — only critical items break through
        let isQuietHours = currentHour >= 23 || currentHour < 7

        if urgency >= 0.9 {
            // Critical — always deliver immediately, even in quiet hours
            return isDND ? .nextInteraction : .immediate
        }

        if isQuietHours {
            // During quiet hours, everything below critical is batched
            return .batch
        }

        if urgency >= 0.6 {
            // High urgency but not critical
            if isDND || isDeepWork {
                return .nextInteraction
            }
            return .immediate
        }

        if urgency >= 0.3 {
            // Medium — show at next interaction
            return .nextInteraction
        }

        // Low urgency — batch for morning
        return .batch
    }
}
