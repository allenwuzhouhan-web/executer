import Foundation

/// Manages seamless transitions between human and AI control.
enum HandoffProtocol {

    enum ControlState {
        case human      // User is in control
        case ai         // AI is executing autonomously
        case shared     // AI suggests, user approves
    }

    /// Current control state.
    static var currentState: ControlState = .human

    /// Hand off control to AI.
    static func handoffToAI() {
        currentState = .ai
        SupervisionMode.shared.activate(description: "AI is working...")
        print("[Handoff] Control transferred to AI")
    }

    /// Take back control from AI.
    static func handoffToHuman() {
        currentState = .human
        SupervisionMode.shared.deactivate()
        print("[Handoff] Control returned to human")
    }

    /// Enter shared mode (AI suggests, user approves).
    static func enterSharedMode() {
        currentState = .shared
        print("[Handoff] Entering shared control mode")
    }
}
