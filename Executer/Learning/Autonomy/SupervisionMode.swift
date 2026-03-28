import Foundation

/// "AI is working" supervision mode — user can intervene at any time.
final class SupervisionMode {
    static let shared = SupervisionMode()

    @Published var isActive = false
    @Published var currentAction: String = ""
    @Published var actionsCompleted: Int = 0

    /// Callback for when user requests stop.
    var onStop: (() -> Void)?

    private init() {}

    func activate(description: String) {
        isActive = true
        currentAction = description
        actionsCompleted = 0
    }

    func updateAction(_ action: String) {
        currentAction = action
        actionsCompleted += 1
    }

    func deactivate() {
        isActive = false
        currentAction = ""
    }

    /// Emergency stop — called when user says "stop".
    func emergencyStop() {
        AutonomyOrchestrator.shared.stop()
        deactivate()
        onStop?()
        print("[SupervisionMode] Emergency stop triggered by user")
    }
}
