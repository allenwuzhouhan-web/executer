import Foundation

/// "Teach Me" mode: heightened observation when user explicitly says "watch what I do."
/// Records the full action sequence and compiles it into a WorkflowTemplate.
final class TeachMeMode {
    static let shared = TeachMeMode()

    private(set) var isActive = false
    private var description: String = ""
    private var recordedActions: [UserAction] = []
    private var startTime: Date?
    private let lock = NSLock()

    /// Original screen sampling interval to restore when mode ends.
    private var originalSamplingInterval: TimeInterval = 60

    private init() {}

    /// Start "Teach Me" mode with heightened observation.
    func start(description: String = "Unnamed workflow") {
        lock.lock()
        self.description = description
        self.recordedActions.removeAll()
        self.startTime = Date()
        self.isActive = true

        // Increase screen sampling frequency
        originalSamplingInterval = LearningConfig.shared.screenSamplingInterval
        LearningConfig.shared.screenSamplingInterval = 5  // 5 seconds instead of 60

        lock.unlock()
        print("[TeachMe] Started recording: \(description)")
    }

    /// Record an action during active teaching.
    func recordAction(_ action: UserAction) {
        guard isActive else { return }
        lock.lock()
        recordedActions.append(action)
        lock.unlock()
    }

    /// Stop recording and compile into a WorkflowTemplate.
    func stop() -> WorkflowTemplate? {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return nil
        }

        isActive = false
        let actions = recordedActions
        let desc = description

        // Restore original sampling interval
        LearningConfig.shared.screenSamplingInterval = originalSamplingInterval

        recordedActions.removeAll()
        lock.unlock()

        guard !actions.isEmpty else {
            print("[TeachMe] No actions recorded")
            return nil
        }

        print("[TeachMe] Stopped. Recorded \(actions.count) actions")

        // Build a pattern from recorded actions
        let patternActions = actions.map { action in
            WorkflowPattern.PatternAction(
                type: action.type,
                elementRole: action.elementRole,
                elementTitle: action.elementTitle,
                elementValue: action.type == .textEdit ? "" : action.elementValue
            )
        }

        let pattern = WorkflowPattern(
            id: UUID(),
            appName: actions.first?.appName ?? "Unknown",
            name: desc,
            actions: patternActions,
            frequency: 1,
            firstSeen: Date(),
            lastSeen: Date()
        )

        // Compile pattern into a template
        guard let template = WorkflowCompiler.compile(pattern) else {
            print("[TeachMe] Failed to compile pattern into template")
            return nil
        }

        // Save to library
        TemplateLibrary.shared.save(template)
        print("[TeachMe] Created template: \(template.name) (\(template.steps.count) steps)")

        return template
    }
}
