import SwiftUI

/// Visual node-graph editor for viewing, editing, and debugging generalized workflows.
///
/// Phase 17 of the Workflow Recorder ("The Cartographer").
/// Displays workflows as interactive flow diagrams where nodes = steps and
/// edges = data flow / dependencies. Supports zoom/pan, editing, breakpoints,
/// and live replay animation.
struct WorkflowEditorView: View {
    @StateObject private var viewModel: WorkflowEditorViewModel
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var selectedNodeId: UUID?
    @State private var showingPalette = false
    @State private var showingParameterEditor = false

    init(workflow: GeneralizedWorkflow) {
        _viewModel = StateObject(wrappedValue: WorkflowEditorViewModel(workflow: workflow))
    }

    var body: some View {
        ZStack {
            // Background
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            // Canvas with nodes and edges
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    ZStack {
                        // Edges (connections between nodes)
                        ForEach(viewModel.edges, id: \.id) { edge in
                            EdgeView(edge: edge, nodes: viewModel.nodePositions)
                        }

                        // Nodes
                        ForEach(viewModel.nodes) { node in
                            NodeView(
                                node: node,
                                isSelected: selectedNodeId == node.id,
                                isExecuting: viewModel.executingNodeId == node.id,
                                hasBreakpoint: viewModel.breakpoints.contains(node.id),
                                onTap: {
                                    selectedNodeId = node.id
                                },
                                onBreakpointToggle: {
                                    viewModel.toggleBreakpoint(node.id)
                                }
                            )
                            .position(
                                x: viewModel.nodePositions[node.id]?.x ?? 0,
                                y: viewModel.nodePositions[node.id]?.y ?? 0
                            )
                        }
                    }
                    .frame(
                        width: max(geometry.size.width, CGFloat(viewModel.nodes.count) * 200),
                        height: max(geometry.size.height, 600)
                    )
                    .scaleEffect(scale)
                }
            }

            // Top bar: workflow name + controls
            VStack {
                HStack {
                    Text(viewModel.workflow.name)
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    // Step count
                    Text("\(viewModel.nodes.count) steps")
                        .font(.caption)
                        .foregroundColor(.gray)

                    // Zoom controls
                    Button(action: { scale = min(scale + 0.1, 2.0) }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    Button(action: { scale = max(scale - 0.1, 0.3) }) {
                        Image(systemName: "minus.magnifyingglass")
                    }

                    Divider().frame(height: 16)

                    // Debug controls
                    Button(action: { viewModel.startDebugReplay() }) {
                        Image(systemName: "play.fill")
                            .foregroundColor(.green)
                    }
                    .disabled(viewModel.isReplaying)

                    Button(action: { viewModel.stepOver() }) {
                        Image(systemName: "arrow.right")
                            .foregroundColor(.blue)
                    }
                    .disabled(!viewModel.isPaused)

                    Button(action: { viewModel.stopReplay() }) {
                        Image(systemName: "stop.fill")
                            .foregroundColor(.red)
                    }
                    .disabled(!viewModel.isReplaying)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                Spacer()

                // Bottom: selected node details
                if let selectedId = selectedNodeId,
                   let node = viewModel.nodes.first(where: { $0.id == selectedId }) {
                    NodeDetailPanel(
                        node: node,
                        onEditParameters: { showingParameterEditor = true },
                        onDelete: { viewModel.removeNode(selectedId); selectedNodeId = nil }
                    )
                }
            }
        }
        .sheet(isPresented: $showingParameterEditor) {
            if let selectedId = selectedNodeId,
               let node = viewModel.nodes.first(where: { $0.id == selectedId }) {
                ParameterEditorSheet(node: node, viewModel: viewModel)
            }
        }
    }
}

// MARK: - Node View

struct NodeView: View {
    let node: EditorNode
    let isSelected: Bool
    let isExecuting: Bool
    let hasBreakpoint: Bool
    let onTap: () -> Void
    let onBreakpointToggle: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            // Operation icon + name
            HStack(spacing: 6) {
                Image(systemName: node.iconName)
                    .font(.system(size: 12))
                    .foregroundColor(node.color)

                Text(node.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            // App context
            Text(node.appContext)
                .font(.system(size: 9))
                .foregroundColor(.gray)

            // Breakpoint indicator
            if hasBreakpoint {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isExecuting ? Color.blue.opacity(0.3) : Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.white.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                )
        )
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("Toggle Breakpoint") { onBreakpointToggle() }
        }
    }
}

// MARK: - Edge View

struct EdgeView: View {
    let edge: EditorEdge
    let nodes: [UUID: CGPoint]

    var body: some View {
        if let from = nodes[edge.fromId], let to = nodes[edge.toId] {
            Path { path in
                path.move(to: from)
                let midY = (from.y + to.y) / 2
                path.addCurve(
                    to: to,
                    control1: CGPoint(x: from.x, y: midY),
                    control2: CGPoint(x: to.x, y: midY)
                )
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
        }
    }
}

// MARK: - Node Detail Panel

struct NodeDetailPanel: View {
    let node: EditorNode
    let onEditParameters: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.description)
                    .font(.system(size: 12))
                    .foregroundColor(.white)

                if !node.parameterBindings.isEmpty {
                    Text("Parameters: \(node.parameterBindings.keys.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }

                if let precondition = node.precondition {
                    Text("Requires: \(precondition)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            Button("Edit") { onEditParameters() }
                .font(.caption)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

// MARK: - Parameter Editor Sheet

struct ParameterEditorSheet: View {
    let node: EditorNode
    @ObservedObject var viewModel: WorkflowEditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Step: \(node.title)")
                .font(.headline)

            ForEach(Array(node.parameterBindings.keys.sorted()), id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .trailing)

                    TextField("Value", text: Binding(
                        get: { node.parameterBindings[key] ?? "" },
                        set: { viewModel.updateParameter(nodeId: node.id, key: key, value: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - View Model

@MainActor
class WorkflowEditorViewModel: ObservableObject {
    @Published var workflow: GeneralizedWorkflow
    @Published var nodes: [EditorNode] = []
    @Published var edges: [EditorEdge] = []
    @Published var nodePositions: [UUID: CGPoint] = [:]
    @Published var breakpoints: Set<UUID> = []
    @Published var executingNodeId: UUID?
    @Published var isReplaying = false
    @Published var isPaused = false

    private var replayTask: Task<Void, Never>?
    private var currentStepIndex = 0

    init(workflow: GeneralizedWorkflow) {
        self.workflow = workflow
        buildGraph()
    }

    // MARK: - Graph Building

    func buildGraph() {
        nodes = workflow.steps.enumerated().map { (i, step) in
            EditorNode(
                id: step.id,
                stepIndex: i,
                operation: step.operation,
                title: step.operation.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                description: step.description,
                appContext: step.appContext,
                parameterBindings: step.parameterBindings,
                precondition: step.precondition
            )
        }

        // Layout: vertical flow
        let startX: CGFloat = 200
        let startY: CGFloat = 60
        let stepY: CGFloat = 80

        for (i, node) in nodes.enumerated() {
            nodePositions[node.id] = CGPoint(x: startX, y: startY + CGFloat(i) * stepY)
        }

        // Build sequential edges
        edges = []
        for i in 0..<(nodes.count - 1) {
            edges.append(EditorEdge(
                id: UUID(),
                fromId: nodes[i].id,
                toId: nodes[i + 1].id
            ))
        }
    }

    // MARK: - Editing

    func removeNode(_ nodeId: UUID) {
        nodes.removeAll { $0.id == nodeId }
        edges.removeAll { $0.fromId == nodeId || $0.toId == nodeId }
        nodePositions.removeValue(forKey: nodeId)
        workflow.steps.removeAll { $0.id == nodeId }
    }

    func updateParameter(nodeId: UUID, key: String, value: String) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }) else { return }
        nodes[idx].parameterBindings[key] = value
    }

    func toggleBreakpoint(_ nodeId: UUID) {
        if breakpoints.contains(nodeId) {
            breakpoints.remove(nodeId)
        } else {
            breakpoints.insert(nodeId)
        }
    }

    // MARK: - Debug Replay

    func startDebugReplay() {
        guard !isReplaying else { return }
        isReplaying = true
        isPaused = false
        currentStepIndex = 0

        replayTask = Task {
            for (i, node) in nodes.enumerated() {
                currentStepIndex = i
                executingNodeId = node.id

                // Check breakpoint
                if breakpoints.contains(node.id) {
                    isPaused = true
                    while isPaused && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }

                guard !Task.isCancelled else { break }

                // Simulate step execution with visual feedback
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            executingNodeId = nil
            isReplaying = false
            isPaused = false
        }
    }

    func stepOver() {
        isPaused = false
    }

    func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
        executingNodeId = nil
        isReplaying = false
        isPaused = false
    }
}

// MARK: - Editor Models

struct EditorNode: Identifiable {
    let id: UUID
    let stepIndex: Int
    let operation: AbstractOperation
    var title: String
    var description: String
    var appContext: String
    var parameterBindings: [String: String]
    var precondition: String?

    var iconName: String {
        switch operation {
        case .switchApp, .launchApp: return "app.badge"
        case .clickElement, .submitForm: return "cursorarrow.click"
        case .fillField, .search, .editText: return "character.cursor.ibeam"
        case .navigateTo: return "safari"
        case .copyContent: return "doc.on.clipboard"
        case .pasteContent: return "clipboard"
        case .saveFile: return "square.and.arrow.down"
        case .openDocument: return "doc"
        case .selectMenuItem: return "filemenu.and.selection"
        case .switchTab: return "rectangle.stack"
        case .deleteFile: return "trash"
        default: return "gearshape"
        }
    }

    var color: Color {
        switch operation {
        case .switchApp, .launchApp, .quitApp: return .blue
        case .clickElement, .submitForm: return .green
        case .fillField, .search, .editText: return .orange
        case .copyContent, .pasteContent: return .purple
        case .saveFile, .openDocument: return .cyan
        case .navigateTo: return .teal
        case .deleteFile: return .red
        default: return .gray
        }
    }
}

struct EditorEdge: Identifiable {
    let id: UUID
    let fromId: UUID
    let toId: UUID
}

// MARK: - Editor Window Controller

/// Standalone NSWindow for the full workflow editor experience.
@MainActor
class WorkflowEditorWindowController {
    private var window: NSWindow?

    static let shared = WorkflowEditorWindowController()

    func show(workflow: GeneralizedWorkflow) {
        if let existing = window {
            existing.close()
        }

        let editorView = WorkflowEditorView(workflow: workflow)
        let hostingView = NSHostingView(rootView: editorView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Workflow Editor — \(workflow.name)"
        newWindow.contentView = hostingView
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.isReleasedWhenClosed = false

        self.window = newWindow
    }
}
