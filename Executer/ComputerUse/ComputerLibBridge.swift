import Foundation
import ComputerLib

/// Bridge between ComputerLib and Executer. Wraps ComputerLib's API for use in the agent loop.
/// Holds shared state (last ScreenMap, cached shortcuts) that multiple systems need.
class ComputerLibBridge {
    static let shared = ComputerLibBridge()

    private(set) var lastMap: ScreenMap?
    private(set) var lastShortcuts: [ShortcutAdvisor.Shortcut] = []
    private(set) var lastDiff: ChangeDetector.ScreenDiff?
    private let db = ElementDatabase.shared

    private init() {}

    // MARK: - Perception

    /// Capture the current screen state via ComputerLib.
    func capture(forceOCR: Bool = false) async -> ScreenMap {
        let map = await PerceptionPipeline.shared.capture(forceOCR: forceOCR)
        lastMap = map

        // Auto-profile for learning
        AppProfile.autoProfile(map: map, db: db)

        return map
    }

    /// Invalidate both ComputerLib and VisionEngine caches.
    func invalidateCache() {
        PerceptionPipeline.shared.invalidateCache()
        VisionEngine.shared.invalidateCache()
    }

    // MARK: - Change Detection

    /// Diff two screen maps.
    func diff(previous: ScreenMap, current: ScreenMap) -> ChangeDetector.ScreenDiff {
        let d = ChangeDetector.diff(previous: previous, current: current)
        lastDiff = d
        return d
    }

    // MARK: - Output

    /// Format a ScreenMap as compact text for LLM injection (~120 tokens vs ~3500).
    func formatForLLM(_ map: ScreenMap) -> String {
        TextFormatter.format(map)
    }

    /// Build a concise diff message for the LLM.
    func buildDiffMessage(_ diff: ChangeDetector.ScreenDiff) -> String {
        var lines: [String] = ["[Screen Update] \(diff.summary)"]

        if !diff.added.isEmpty {
            let labels = diff.added.prefix(5).map { "\(String(describing: $0.ref)) \"\($0.label)\"" }
            lines.append("+ \(labels.joined(separator: ", "))")
            if diff.added.count > 5 { lines.append("  +\(diff.added.count - 5) more") }
        }

        if !diff.removed.isEmpty {
            lines.append("- \(diff.removed.count) elements removed")
        }

        if !diff.changed.isEmpty {
            let descs = diff.changed.prefix(5).map { "\(String(describing: $0.ref)).\($0.field)" }
            lines.append("~ \(descs.joined(separator: ", "))")
            if diff.changed.count > 5 { lines.append("  +\(diff.changed.count - 5) more") }
        }

        // Safety alerts for new dangerous elements
        if let map = lastMap {
            for ref in map.safety.dangers {
                if diff.added.contains(where: { $0.ref == ref }) {
                    let el = map.elements.first(where: { $0.ref == ref })
                    lines.append("DANGER: \(String(describing: ref)) \"\(el?.label ?? "?")\"")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Element Resolution

    /// Resolve an @e ref string to its element and click point.
    func resolveRef(_ refString: String) -> (element: ScreenElement, clickPoint: CGPoint)? {
        guard let map = lastMap else { return nil }
        guard let element = Disambiguator.findByRef(refString, in: map) else { return nil }
        guard let clickPoint = element.clickPoint else { return nil }
        return (element, clickPoint)
    }

    // MARK: - Safety

    /// Check if clicking an element is dangerous.
    func checkSafety(refString: String) -> DangerDetector.DangerResult? {
        guard let map = lastMap,
              let element = Disambiguator.findByRef(refString, in: map) else { return nil }

        let windowTitle = map.windows.first(where: { $0.isFocused })?.title ?? ""
        let context = DangerDetector.ScanContext(
            appBundleID: map.focusedApp.bundleID,
            windowTitle: windowTitle
        )
        let result = DangerDetector.classify(element: element, context: context)
        return result.level > .safe ? result : nil
    }

    // MARK: - Learning

    /// Record a successful interaction with an element.
    func recordSuccess(refString: String, action: String) {
        guard let map = lastMap,
              let element = Disambiguator.findByRef(refString, in: map) else { return }
        let hash = UnknownElementHandler.elementHash(element: element, appBundleID: map.focusedApp.bundleID)
        db.recordCorrectMatch(hash: hash)
    }

    /// Record a failed interaction.
    func recordFailure(refString: String, action: String, error: String) {
        guard let map = lastMap else { return }
        FailureLog.log(
            expectedMap: nil,
            actualMap: map,
            elementRef: ElementRef.parse(refString),
            actionAttempted: action,
            errorDescription: error,
            db: db
        )
    }

    // MARK: - Shortcuts

    /// Discover keyboard shortcuts for the frontmost app (cached).
    func discoverShortcuts() -> [ShortcutAdvisor.Shortcut] {
        let shortcuts = ShortcutAdvisor.discoverShortcuts()
        lastShortcuts = shortcuts
        return shortcuts
    }

    // MARK: - Context Injection

    /// Get confusion pattern summary for LLM prompt injection.
    func confusionSummary() -> String? {
        CorrectionLoop.confusionSummary(appBundleID: lastMap?.focusedApp.bundleID, db: db)
    }

    /// Get current undo state.
    func undoState() -> UndoAdvisor.UndoState {
        UndoAdvisor.checkUndoState()
    }
}
