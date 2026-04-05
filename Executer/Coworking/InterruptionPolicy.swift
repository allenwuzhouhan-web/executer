import Foundation

/// Pure-function evaluator that determines if it's safe to surface a suggestion right now.
/// No state — all decisions are based on the WorkState snapshot.
enum InterruptionPolicy {

    /// Returns true if now is a natural pause moment where a suggestion won't disrupt.
    static func isSafeToInterrupt(state: WorkState) -> Bool {
        // Never interrupt during presentations
        if state.activityType == .presenting {
            return false
        }

        // Never interrupt in blocked focus modes
        switch state.focusMode {
        case .doNotDisturb, .sleep, .driving, .mindfulness:
            return false
        default:
            break
        }

        // Require at least 5s pause before interrupting
        if state.idleSeconds < 5 {
            return false
        }

        // In Work/Reading focus + coding/writing, require 10s pause
        let deepFocusActivities: Set<WorkState.ActivityType> = [.coding, .writing, .reading]
        let isDeepFocus = (state.focusMode == .work || state.focusMode == .reading)
        if isDeepFocus && deepFocusActivities.contains(state.activityType) {
            if state.idleSeconds < 10 {
                return false
            }
        }

        return true
    }

    /// Returns the number of seconds to wait before checking again.
    static func retryDelay(state: WorkState) -> TimeInterval {
        // Actively working: check again in 10s
        if state.idleSeconds < 2 {
            return 10
        }

        // Deep focus (coding in Work mode): check again in 30s
        let deepFocusActivities: Set<WorkState.ActivityType> = [.coding, .writing]
        let isDeepFocus = (state.focusMode == .work || state.focusMode == .reading)
        if isDeepFocus && deepFocusActivities.contains(state.activityType) {
            return 30
        }

        // Default: 15s
        return 15
    }
}
