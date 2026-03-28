import Foundation

/// Watches user actions after a workflow failure to learn the correct sequence.
final class CorrectionLearner {
    static let shared = CorrectionLearner()

    private var watchingForCorrection = false
    private var failedTemplateId: UUID?
    private var failedAtStep: Int = 0
    private var correctionActions: [UserAction] = []

    private init() {}

    /// Start watching for user corrections after a failure.
    func startWatching(templateId: UUID, failedStep: Int) {
        watchingForCorrection = true
        failedTemplateId = templateId
        failedAtStep = failedStep
        correctionActions.removeAll()

        // Auto-stop after 5 minutes
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.stopWatching()
        }
    }

    /// Record a user action during correction watching.
    func recordAction(_ action: UserAction) {
        guard watchingForCorrection else { return }
        correctionActions.append(action)
    }

    /// Stop watching and attempt to learn the correction.
    func stopWatching() {
        guard watchingForCorrection, !correctionActions.isEmpty else {
            watchingForCorrection = false
            return
        }

        watchingForCorrection = false
        print("[CorrectionLearner] Learned \(correctionActions.count) correction actions for template step \(failedAtStep)")

        // In future phases, use these actions to update the template
        correctionActions.removeAll()
    }
}
