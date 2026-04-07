import Foundation
import ComputerLib

/// Tool that lets the agent explore an app's UI by systematically clicking elements,
/// observing what happens (before/after screen state), and saving learned behaviors
/// to the ui_knowledge database for future use.
///
/// The agent can run this autonomously (e.g., overnight) to build up knowledge of
/// how apps work, so next time it needs to navigate an app, it already knows what
/// each button does.
struct UIExploreTool: ToolDefinition {
    let name = "explore_ui"
    let description = """
    Explore an app's UI to learn what elements do. Clicks an element, captures before/after screen state, \
    and saves the learned behavior. Use this to build knowledge about unfamiliar apps. \
    Can explore a single element or scan multiple elements in the current view. \
    Learned knowledge is automatically injected into future interactions with the same app.
    """
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "mode": JSONSchema.string(description: "Exploration mode: 'single' to explore one element by ref, 'scan' to explore all safe elements in the current view. Default: 'single'"),
            "ref": JSONSchema.string(description: "Element reference to explore (e.g., '@e5'). Required for 'single' mode."),
            "app_name": JSONSchema.string(description: "App name to associate learnings with. If omitted, uses the frontmost app."),
            "max_elements": JSONSchema.integer(description: "Max elements to explore in 'scan' mode. Default: 10."),
            "safe_only": JSONSchema.boolean(description: "Only explore safe elements (skip danger/destructive). Default: true."),
        ])
    }

    private static let dangerWords = [
        "delete", "remove", "logout", "sign out", "deactivate", "uninstall",
        "format", "erase", "quit", "close", "exit", "trash", "destroy",
        "send", "submit", "post", "publish", "save", "apply",
        "enable", "disable", "turn on", "turn off", "reset",
        "purchase", "buy", "pay", "subscribe", "upgrade",
    ]

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let mode = optionalString("mode", from: args) ?? "single"
        let appNameOverride = optionalString("app_name", from: args)
        let maxElements = optionalInt("max_elements", from: args) ?? 10
        let safeOnly = (args["safe_only"] as? Bool) ?? true

        let bridge = ComputerLibBridge.shared

        // Capture current screen state
        let beforeMap = await bridge.capture(forceOCR: false)
        let appName = appNameOverride ?? beforeMap.focusedApp.name

        if mode == "scan" {
            return await scanExplore(bridge: bridge, beforeMap: beforeMap, appName: appName, maxElements: maxElements, safeOnly: safeOnly)
        } else {
            guard let refString = optionalString("ref", from: args) else {
                return "Error: 'ref' parameter required for single mode (e.g., '@e5')"
            }
            guard let ref = ElementRef.parse(refString) else {
                return "Error: Invalid ref format '\(refString)'. Use @eN format (e.g., '@e5')."
            }
            return await exploreSingleElement(bridge: bridge, beforeMap: beforeMap, ref: ref, appName: appName, safeOnly: safeOnly)
        }
    }

    // MARK: - Single Element Exploration

    private func exploreSingleElement(
        bridge: ComputerLibBridge,
        beforeMap: ScreenMap,
        ref: ElementRef,
        appName: String,
        safeOnly: Bool
    ) async -> String {
        guard let element = beforeMap.elements.first(where: { $0.ref == ref }) else {
            return "Error: Element \(ref) not found on screen. Screen may have changed."
        }

        // Safety check
        if safeOnly {
            if isDangerous(element) {
                return "Skipped \(ref) \"\(element.label)\" — potentially destructive."
            }
        }

        let sectionPath = buildSectionPath(for: element, in: beforeMap)

        guard let clickPoint = element.clickPoint else {
            return "Error: Element \(ref) \"\(element.label)\" has no click point."
        }

        // Click via ClickTool (same mechanism as click_ref)
        let clickArgs = "{\"x\": \(Int(clickPoint.x)), \"y\": \(Int(clickPoint.y))}"
        _ = try? await ClickTool().execute(arguments: clickArgs)

        // Wait for UI to settle
        try? await Task.sleep(nanoseconds: 800_000_000)

        // Capture after state
        bridge.invalidateCache()
        let afterMap = await bridge.capture(forceOCR: false)
        let diff = bridge.diff(previous: beforeMap, current: afterMap)

        let resultDescription = analyzeChange(diff: diff, beforeMap: beforeMap, afterMap: afterMap, clickedElement: element)

        // Save to learning database
        LearningDatabase.shared.upsertUIKnowledge(
            appName: appName,
            appBundleID: beforeMap.focusedApp.bundleID,
            sectionPath: sectionPath,
            elementLabel: element.label,
            elementRole: element.role.rawValue,
            actionType: "click",
            resultDescription: resultDescription
        )

        // Undo the action if possible
        let undoState = bridge.undoState()
        if undoState.canUndo {
            _ = try? await HotkeyTool().execute(arguments: "{\"combo\": \"cmd+z\"}")
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return """
        Explored \(ref) [\(element.role.rawValue)] "\(element.label)" in "\(sectionPath)"
        Result: \(resultDescription)
        \(undoState.canUndo ? "Action undone." : "Note: Could not undo — manual check advised.")
        Saved to UI knowledge database for \(appName).
        """
    }

    // MARK: - Scan Exploration

    private func scanExplore(
        bridge: ComputerLibBridge,
        beforeMap: ScreenMap,
        appName: String,
        maxElements: Int,
        safeOnly: Bool
    ) async -> String {
        let interactive = beforeMap.elements.filter { $0.role.isInteractive }
        var explored: [(ref: String, label: String, result: String)] = []
        var skipped = 0

        // Pre-fetch existing knowledge to avoid re-exploring known elements
        let existingKnowledge = LearningDatabase.shared.queryUIKnowledge(forApp: appName, limit: 200)
        let knownSet = Set(existingKnowledge.map { "\($0.sectionPath)|\($0.elementLabel)" })

        for element in interactive.prefix(maxElements * 2) {
            if explored.count >= maxElements { break }

            // Safety filter
            if safeOnly {
                if isDangerous(element) { skipped += 1; continue }
                if element.state.contains(.disabled) { skipped += 1; continue }
            }

            // Skip unlabeled elements
            if element.label.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Skip already-known elements
            let sectionPath = buildSectionPath(for: element, in: beforeMap)
            if knownSet.contains("\(sectionPath)|\(element.label)") { continue }

            guard let clickPoint = element.clickPoint else { continue }

            // Capture before
            let preMap = await bridge.capture(forceOCR: false)

            // Click
            _ = try? await ClickTool().execute(arguments: "{\"x\": \(Int(clickPoint.x)), \"y\": \(Int(clickPoint.y))}")
            try? await Task.sleep(nanoseconds: 800_000_000)

            // Capture after
            bridge.invalidateCache()
            let postMap = await bridge.capture(forceOCR: false)
            let diff = bridge.diff(previous: preMap, current: postMap)
            let resultDescription = analyzeChange(diff: diff, beforeMap: preMap, afterMap: postMap, clickedElement: element)

            // Save learning
            LearningDatabase.shared.upsertUIKnowledge(
                appName: appName,
                appBundleID: beforeMap.focusedApp.bundleID,
                sectionPath: sectionPath,
                elementLabel: element.label,
                elementRole: element.role.rawValue,
                actionType: "click",
                resultDescription: resultDescription
            )

            explored.append((ref: element.ref.description, label: element.label, result: resultDescription))

            // Undo
            let undoState = bridge.undoState()
            if undoState.canUndo {
                _ = try? await HotkeyTool().execute(arguments: "{\"combo\": \"cmd+z\"}")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            // Escape any dialogs/menus that opened
            if diff.hasMajorChange {
                _ = try? await PressKeyTool().execute(arguments: "{\"key\": \"escape\"}")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        var report = ["UI Exploration Report for \(appName)"]
        report.append("Explored \(explored.count) elements, skipped \(skipped) (unsafe/disabled)")
        report.append("")
        for e in explored {
            report.append("  \(e.ref) \"\(e.label)\" → \(e.result)")
        }
        report.append("")
        report.append("All learnings saved to UI knowledge database.")

        return report.joined(separator: "\n")
    }

    // MARK: - Change Analysis

    private func analyzeChange(
        diff: ChangeDetector.ScreenDiff,
        beforeMap: ScreenMap,
        afterMap: ScreenMap,
        clickedElement: ScreenElement
    ) -> String {
        var effects: [String] = []

        if diff.appSwitched {
            effects.append("Switched to \(diff.currentApp ?? "another app")")
        }

        let beforeDialogs = beforeMap.elements.filter { $0.role == .dialog || $0.role == .sheet }
        let afterDialogs = afterMap.elements.filter { $0.role == .dialog || $0.role == .sheet }
        if afterDialogs.count > beforeDialogs.count {
            let newDialog = afterDialogs.last
            effects.append("Opens dialog\(newDialog.map { ": \"\($0.label)\"" } ?? "")")
        }
        if afterDialogs.count < beforeDialogs.count {
            effects.append("Closes dialog")
        }

        if afterMap.windows.count > beforeMap.windows.count {
            effects.append("Opens new window")
        }

        // Menu appeared
        if diff.added.count > 5 {
            let menuItems = diff.added.filter { $0.role == .menuItem }
            if menuItems.count >= 3 {
                let itemLabels = menuItems.prefix(3).map { "\"\($0.label)\"" }.joined(separator: ", ")
                effects.append("Opens menu with \(menuItems.count) items: \(itemLabels)...")
            }
        }

        // New elements added
        if !diff.added.isEmpty && effects.isEmpty {
            let labeled = diff.added.filter { !$0.label.isEmpty }
            if !labeled.isEmpty {
                let labels = labeled.prefix(3).map { "\"\($0.label)\"" }.joined(separator: ", ")
                effects.append("Shows: \(labels)")
            }
        }

        if diff.removed.count > 3 && effects.isEmpty {
            effects.append("Hides \(diff.removed.count) elements")
        }

        for change in diff.changed.prefix(3) {
            if change.field == "value" {
                effects.append("Changed value of \(change.ref)")
            }
        }

        if let beforeNav = beforeMap.navigation, let afterNav = afterMap.navigation, beforeNav != afterNav {
            effects.append("Navigated to: \(afterNav.joined(separator: " > "))")
        }

        if clickedElement.role == .checkbox || clickedElement.role == .toggle {
            effects.append("Toggles \(clickedElement.label)")
        }

        if effects.isEmpty {
            if diff.isEmpty {
                effects.append("No visible change (may require additional input or context)")
            } else {
                effects.append("Minor UI update")
            }
        }

        return effects.joined(separator: "; ")
    }

    // MARK: - Helpers

    private func isDangerous(_ element: ScreenElement) -> Bool {
        let lowerLabel = element.label.lowercased()
        return Self.dangerWords.contains(where: { lowerLabel.contains($0) })
    }

    private func buildSectionPath(for element: ScreenElement, in map: ScreenMap) -> String {
        let elementByRef = Dictionary(map.elements.map { ($0.ref, $0) }, uniquingKeysWith: { f, _ in f })
        var labels: [String] = []
        var current = element
        while let pRef = current.parentRef, let parent = elementByRef[pRef] {
            if parent.role.isContainer && !parent.label.isEmpty {
                labels.append(String(parent.label.prefix(40)))
            }
            current = parent
        }
        labels.reverse()
        return labels.joined(separator: " > ")
    }
}
