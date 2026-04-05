import Foundation
import ComputerLib

/// Ensures AICursorManager is active for cursor visualization.
private func ensureAICursorActiveForRef() {
    if !AICursorManager.shared.isActive {
        DispatchQueue.main.async {
            AICursorManager.shared.startAIControl()
        }
    }
}

/// Click a screen element by its @e reference (e.g., @e5).
/// Resolves the ref from the last ComputerLib screen capture, checks safety, then clicks.
struct ClickRefTool: ToolDefinition {
    let name = "click_ref"
    let description = "Click a screen element by its @e reference (e.g., @e5). Use this for precise targeting after reading the screen state. Faster and more reliable than click_element."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "ref": JSONSchema.string(description: "Element reference in @e format (e.g., '@e5', '@e12')"),
            "button": JSONSchema.string(description: "Mouse button: 'left' (default) or 'right'"),
            "count": JSONSchema.integer(description: "Click count: 1 for single (default), 2 for double-click"),
        ], required: ["ref"])
    }

    func execute(arguments: String) async throws -> String {
        ensureAICursorActiveForRef()
        let args = try parseArguments(arguments)
        let refString = try requiredString("ref", from: args)
        let button = optionalString("button", from: args) ?? "left"
        let count = optionalInt("count", from: args) ?? 1

        let bridge = ComputerLibBridge.shared

        // 1. Resolve ref to element + click point
        guard let resolved = bridge.resolveRef(refString) else {
            return "Element \(refString) not found on current screen. The screen may have changed — perceive again."
        }

        let label = resolved.element.label
        let point = resolved.clickPoint

        // 2. Safety check — block dangerous elements
        if let danger = bridge.checkSafety(refString: refString) {
            if danger.level == .dangerous {
                bridge.recordFailure(refString: refString, action: "click_ref", error: "Blocked: dangerous element")
                return "BLOCKED: \(refString) \"\(label)\" is dangerous — \(danger.reason ?? "destructive action"). Get user confirmation first."
            }
        }

        // 3. Perform the click via the existing ClickTool
        let clickArgs = "{\"x\": \(Int(point.x)), \"y\": \(Int(point.y)), \"button\": \"\(button)\", \"count\": \(count)}"
        let clickResult = try await ClickTool().execute(arguments: clickArgs)

        // 4. Record success for learning
        bridge.recordSuccess(refString: refString, action: "click_ref")

        // 5. Include context in result
        let safetyNote: String
        if let danger = bridge.checkSafety(refString: refString), danger.level == .caution {
            safetyNote = " [CAUTION: \(danger.reason ?? "state-changing")]"
        } else {
            safetyNote = ""
        }

        return "Clicked \(refString) \"\(label)\" at (\(Int(point.x)),\(Int(point.y))).\(safetyNote)"
    }
}
