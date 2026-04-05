import Foundation

/// Classifies concrete JournalEntry actions into abstract operations
/// from the ~30-operation taxonomy defined in AbstractOperation.
///
/// Uses a multi-signal approach:
/// 1. Entry's sourceType (userAction, fileEvent, etc.)
/// 2. Entry's intentCategory from JournalManager
/// 3. Element context keywords (role + title patterns)
/// 4. Semantic action text analysis
enum ActionAbstractor {

    // MARK: - Main Classification

    /// Classify a JournalEntry into an AbstractStep.
    static func abstract(_ entry: JournalEntry) -> AbstractStep {
        let operation = classifyOperation(entry)
        let target = buildTarget(entry)

        return AbstractStep(
            operation: operation,
            target: target,
            appContext: entry.appContext,
            parameterBindings: extractParameterHints(entry, operation: operation),
            precondition: inferPrecondition(entry, operation: operation),
            description: buildDescription(entry, operation: operation)
        )
    }

    /// Classify the abstract operation from a journal entry.
    static func classifyOperation(_ entry: JournalEntry) -> AbstractOperation {
        let action = entry.semanticAction.lowercased()
        let element = entry.elementContext.lowercased()

        // System events
        if entry.sourceType == .systemEvent {
            if action.contains("launched") || action.contains("launch") { return .launchApp }
            if action.contains("quit") || action.contains("closed app") { return .quitApp }
            return .custom
        }

        // File events
        if entry.sourceType == .fileEvent {
            if action.contains("created") { return .saveFile }
            if action.contains("modified") { return .saveFile }
            if action.contains("deleted") { return .deleteFile }
            if action.contains("renamed") { return .renameFile }
            return .moveFile
        }

        // Clipboard events
        if entry.sourceType == .clipboardFlow {
            if action.contains("copied") { return .copyContent }
            return .pasteContent
        }

        // User actions — classify by semantic action + element context
        return classifyUserAction(action: action, element: element, entry: entry)
    }

    // MARK: - User Action Classification

    private static func classifyUserAction(action: String, element: String, entry: JournalEntry) -> AbstractOperation {
        // Text editing
        if action.contains("edited text") || action.contains("typed") {
            if element.contains("search") || element.contains("query") { return .search }
            if element.contains("url") || element.contains("address") { return .navigateTo }
            return .fillField
        }

        // Menu selections
        if action.contains("selected menu") || action.contains("menu item") {
            let title = entry.semanticAction.lowercased()
            if title.contains("new") { return .openDocument }
            if title.contains("open") { return .openDocument }
            if title.contains("close") { return .closeDocument }
            if title.contains("save as") { return .saveAsFile }
            if title.contains("save") { return .saveFile }
            if title.contains("copy") { return .copyContent }
            if title.contains("paste") { return .pasteContent }
            if title.contains("quit") { return .quitApp }
            return .selectMenuItem
        }

        // Window events
        if action.contains("opened window") { return .openWindow }
        if action.contains("closed window") { return .closeWindow }

        // Tab events
        if action.contains("switched to tab") || action.contains("tab") { return .switchTab }

        // Clicks — classify by element type
        if action.contains("clicked") {
            if element.contains("button") {
                let label = entry.elementContext.lowercased()
                if label.contains("submit") || label.contains("send") || label.contains("ok") || label.contains("done") {
                    return .submitForm
                }
                if label.contains("cancel") || label.contains("close") { return .closeWindow }
                if label.contains("save") { return .saveFile }
                if label.contains("search") { return .search }
                return .clickElement
            }
            if element.contains("checkbox") || element.contains("switch") || element.contains("radio") {
                return .toggleOption
            }
            if element.contains("menu") || element.contains("menuitem") { return .selectMenuItem }
            if element.contains("link") { return .navigateTo }
            if element.contains("tab") { return .switchTab }
            if element.contains("popup") || element.contains("combobox") || element.contains("picker") {
                return .selectItem
            }
            return .clickElement
        }

        // Focus events
        if action.contains("focused") {
            if element.contains("textfield") || element.contains("textarea") { return .fillField }
            return .clickElement
        }

        return .custom
    }

    // MARK: - Target Building

    /// Build a semantic ElementTarget from a journal entry.
    private static func buildTarget(_ entry: JournalEntry) -> ElementTarget {
        let parts = entry.elementContext.split(separator: " ", maxSplits: 1)
        let elementType = parts.first.map(String.init) ?? ""
        let label = parts.count > 1 ? String(parts[1]) : ""

        // Infer semantic role from element type + context
        let role = inferRole(elementType: elementType, label: label, action: entry.semanticAction)

        return ElementTarget(
            role: role,
            label: label,
            elementType: elementType,
            positionalHint: ""
        )
    }

    /// Infer a semantic role description for the element.
    private static func inferRole(elementType: String, label: String, action: String) -> String {
        let type = elementType.lowercased()
            .replacingOccurrences(of: "ax", with: "")

        // Build a readable role
        if !label.isEmpty {
            return "\(label) \(type)".trimmingCharacters(in: .whitespaces)
        }

        switch type {
        case "button": return "button"
        case "textfield", "textarea": return "text field"
        case "checkbox": return "checkbox"
        case "menuitem": return "menu item"
        case "link": return "link"
        case "tab": return "tab"
        case "popupbutton", "combobox": return "dropdown"
        case "table", "outline": return "list"
        default: return type.isEmpty ? "element" : type
        }
    }

    // MARK: - Parameter Hints

    /// Extract parameter hints — fields that are likely variable across instances.
    private static func extractParameterHints(_ entry: JournalEntry, operation: AbstractOperation) -> [String: String] {
        var hints: [String: String] = [:]

        switch operation {
        case .fillField, .search, .editText:
            // Text fields almost always contain variable content
            hints["input_text"] = "{{text}}"
        case .navigateTo:
            hints["destination"] = "{{url_or_path}}"
        case .openDocument:
            hints["document"] = "{{document_name}}"
        case .saveAsFile:
            hints["filename"] = "{{filename}}"
        case .launchApp, .switchApp:
            hints["app"] = entry.appContext
        case .moveFile:
            hints["destination"] = "{{destination_path}}"
        default:
            break
        }

        return hints
    }

    // MARK: - Precondition Inference

    /// Infer what must be true before this step can execute.
    private static func inferPrecondition(_ entry: JournalEntry, operation: AbstractOperation) -> String? {
        switch operation {
        case .switchApp, .launchApp:
            return nil  // No precondition — this IS the setup
        case .fillField, .search, .editText, .clickElement, .submitForm, .selectItem, .toggleOption:
            return "app_is_frontmost:\(entry.appContext)"
        case .saveFile, .saveAsFile, .closeDocument:
            return "document_is_open"
        case .navigateTo:
            return "app_is_frontmost:\(entry.appContext)"
        case .copyContent:
            return "content_is_selected"
        case .pasteContent:
            return "clipboard_has_content"
        default:
            return nil
        }
    }

    // MARK: - Description Building

    /// Build a human-readable description of the abstract step.
    private static func buildDescription(_ entry: JournalEntry, operation: AbstractOperation) -> String {
        let app = entry.appContext
        let target = entry.elementContext

        switch operation {
        case .switchApp: return "Switch to \(app)"
        case .launchApp: return "Launch \(app)"
        case .quitApp: return "Quit \(app)"
        case .openDocument: return "Open document in \(app)"
        case .closeDocument: return "Close document in \(app)"
        case .navigateTo: return "Navigate to destination in \(app)"
        case .clickElement: return "Click \(target.isEmpty ? "element" : target) in \(app)"
        case .fillField: return "Enter text in \(target.isEmpty ? "field" : target) in \(app)"
        case .search: return "Search in \(app)"
        case .submitForm: return "Submit form in \(app)"
        case .selectItem: return "Select item from \(target.isEmpty ? "list" : target) in \(app)"
        case .selectMenuItem: return "Select menu item in \(app)"
        case .saveFile: return "Save in \(app)"
        case .copyContent: return "Copy content from \(app)"
        case .pasteContent: return "Paste content in \(app)"
        case .switchTab: return "Switch tab in \(app)"
        case .toggleOption: return "Toggle \(target.isEmpty ? "option" : target) in \(app)"
        default: return "\(operation.rawValue) in \(app)"
        }
    }
}
