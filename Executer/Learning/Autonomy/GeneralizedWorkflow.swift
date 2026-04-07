import Foundation

// MARK: - Generalized Workflow

/// A transferable, parameterized workflow description produced by the SemanticGeneralizer.
///
/// Unlike WorkflowTemplate (which maps 1:1 to tool calls with {{placeholder}} args),
/// a GeneralizedWorkflow describes WHAT to accomplish at a semantic level, leaving
/// HOW to the AdaptiveReplayEngine (Phase 7). This is the leap from "macro recorder"
/// to "workflow intelligence."
///
/// Example: instead of "click button at (312,445) titled 'Submit'",
/// the generalized form is "submit the current form in the active browser."
struct GeneralizedWorkflow: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String                            // "File invoice into folder"
    var description: String                     // Human-readable summary of the workflow
    var steps: [AbstractStep]                   // Ordered sequence of abstract operations
    var parameters: [WorkflowParameter]         // Discovered variable slots
    var applicability: ApplicabilityCondition    // What apps/contexts this works in
    var sourceJournalId: UUID?                  // Journal it was generalized from
    var category: String                        // TopicClassifier topic (coding, writing, etc.)
    var confidence: Double                      // How confident the generalization is (0–1)
    var createdAt: Date
    var timesUsed: Int = 0

    init(
        name: String,
        description: String,
        steps: [AbstractStep],
        parameters: [WorkflowParameter] = [],
        applicability: ApplicabilityCondition,
        sourceJournalId: UUID? = nil,
        category: String = "other",
        confidence: Double = 0.5
    ) {
        self.id = UUID()
        self.name = name
        self.description = description
        self.steps = steps
        self.parameters = parameters
        self.applicability = applicability
        self.sourceJournalId = sourceJournalId
        self.category = category
        self.confidence = confidence
        self.createdAt = Date()
    }

    /// Brief summary for display.
    var summary: String {
        "\(name) — \(steps.count) steps, \(parameters.count) params [\(category)]"
    }
}

// MARK: - Abstract Step

/// A single semantic operation within a generalized workflow.
/// Describes WHAT to do using role-based element references,
/// not coordinates or specific identifiers.
struct AbstractStep: Codable, Sendable {
    let id: UUID
    let operation: AbstractOperation        // What action to perform
    let target: ElementTarget               // What element to act on (semantic)
    let appContext: String                   // Which app this happens in
    let parameterBindings: [String: String]  // Maps parameter names to step fields
    let precondition: String?               // Optional: what must be true before this step
    let description: String                 // Human-readable description

    init(
        operation: AbstractOperation,
        target: ElementTarget,
        appContext: String,
        parameterBindings: [String: String] = [:],
        precondition: String? = nil,
        description: String
    ) {
        self.id = UUID()
        self.operation = operation
        self.target = target
        self.appContext = appContext
        self.parameterBindings = parameterBindings
        self.precondition = precondition
        self.description = description
    }
}

// MARK: - Abstract Operation Taxonomy

/// ~30 abstract operations covering the space of user actions.
/// Each maps to one or more concrete tool calls during replay.
enum AbstractOperation: String, Codable, Sendable, CaseIterable {
    // Navigation
    case switchApp              // Activate a different application
    case openDocument           // Open a file/document
    case closeDocument          // Close a file/document
    case navigateTo             // Navigate to a URL, page, or section
    case switchTab              // Switch browser/editor tab
    case openMenu               // Open a menu

    // Interaction
    case clickElement           // Click a button, link, or interactive element
    case doubleClick            // Double-click (open, rename, etc.)
    case rightClick             // Context menu
    case selectItem             // Select from a list, dropdown, or picker
    case selectMenuItem         // Choose a menu item
    case toggleOption           // Toggle a checkbox, switch, or radio button

    // Text Input
    case fillField              // Type text into a text field
    case editText               // Modify existing text content
    case clearField             // Clear a text field
    case submitForm             // Submit a form (Enter key or submit button)
    case search                 // Enter a search query

    // Data Transfer
    case copyContent            // Copy to clipboard
    case pasteContent           // Paste from clipboard
    case dragAndDrop            // Drag from source to target

    // File Operations
    case saveFile               // Save the current document (Cmd+S)
    case saveAsFile             // Save As with new name/location
    case moveFile               // Move a file to a new location
    case deleteFile             // Delete/trash a file
    case renameFile             // Rename a file

    // Window Management
    case openWindow             // Open a new window
    case closeWindow            // Close a window
    case resizeWindow           // Resize or reposition a window

    // System
    case launchApp              // Launch an application
    case quitApp                // Quit an application
    case waitForState           // Wait for a specific UI state
    case custom                 // Custom/unclassified operation
}

// MARK: - Element Target

/// Semantic reference to a UI element by role and description,
/// not by coordinates or specific AX identifier.
struct ElementTarget: Codable, Sendable {
    let role: String            // Semantic role: "search box", "submit button", "filename field"
    let label: String           // Expected label/title (approximate match)
    let elementType: String     // AX role hint: "AXButton", "AXTextField", etc.
    let positionalHint: String  // Relative position hint: "top-right", "bottom-center", etc.

    init(role: String, label: String = "", elementType: String = "", positionalHint: String = "") {
        self.role = role
        self.label = label
        self.elementType = elementType
        self.positionalHint = positionalHint
    }
}

// MARK: - Workflow Parameter

/// A discovered variable slot in a generalized workflow.
struct WorkflowParameter: Codable, Sendable {
    let name: String            // "filename", "search_query", "recipient"
    let type: ParameterType     // Inferred type
    let description: String     // "The file to process"
    let defaultValue: String?   // From the original observation
    let exampleValues: [String] // Values seen across instances
    let stepBindings: [UUID]    // Which steps use this parameter

    enum ParameterType: String, Codable, Sendable {
        case text               // General text
        case filepath           // File path
        case url                // URL
        case email              // Email address
        case date               // Date/time
        case number             // Numeric value
        case appName            // Application name
        case menuItem           // Menu item selection
        case enumeration        // One of a known set
    }
}

// MARK: - Applicability Condition

/// Describes what context a generalized workflow applies to.
struct ApplicabilityCondition: Codable, Sendable {
    let requiredApps: [String]          // Apps that must be available
    let primaryApp: String              // Main app the workflow operates in
    let category: String                // Topic category (coding, writing, etc.)
    let keywords: [String]              // Trigger keywords for recall matching
}
