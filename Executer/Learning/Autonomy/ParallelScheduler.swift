import Foundation

/// Analyzes workflow step dependencies and executes independent branches concurrently.
///
/// Phase 12 of the Workflow Recorder ("The Parallelizer").
/// Builds a DAG from data flow + app exclusivity constraints,
/// identifies independent branches, and runs them concurrently
/// with synchronization barriers.
///
/// Example: "Fetch sales data" + "Fetch support data" + "Fetch analytics"
/// → all three run in parallel; "Compile report" waits for all three.
enum ParallelScheduler {

    // MARK: - DAG Construction

    /// Build a dependency graph from a workflow's steps.
    /// Dependencies are inferred from:
    /// 1. Data flow: step B uses a parameter produced by step A
    /// 2. App exclusivity: only one step can control an app at a time
    /// 3. Sequential ordering for same-app steps
    static func buildDAG(from workflow: GeneralizedWorkflow) -> WorkflowDAG {
        let steps = workflow.steps
        var nodes: [DAGNode] = steps.enumerated().map { (i, step) in
            DAGNode(id: step.id, stepIndex: i, step: step, dependencies: [])
        }

        // Rule 1: Same-app steps must be sequential (can't control two windows simultaneously)
        var lastStepByApp: [String: Int] = [:]
        for i in 0..<steps.count {
            let app = steps[i].appContext
            if let prev = lastStepByApp[app] {
                nodes[i].dependencies.insert(nodes[prev].id)
            }
            lastStepByApp[app] = i
        }

        // Rule 2: Data flow dependencies
        // If step B has a parameter binding that references a key produced by step A
        var producedKeys: [String: Int] = [:]  // key → step index that produces it
        for (i, step) in steps.enumerated() {
            // Steps that produce data: copy, extract, save
            if [.copyContent, .saveFile, .saveAsFile].contains(step.operation) {
                for key in step.parameterBindings.keys {
                    producedKeys[key] = i
                }
            }
        }
        for (i, step) in steps.enumerated() {
            for (_, template) in step.parameterBindings {
                if template.hasPrefix("{{") && template.hasSuffix("}}") {
                    let paramName = String(template.dropFirst(2).dropLast(2))
                    if let producerIndex = producedKeys[paramName], producerIndex != i {
                        nodes[i].dependencies.insert(nodes[producerIndex].id)
                    }
                }
            }
        }

        // Rule 3: Paste depends on the preceding Copy
        for i in 0..<steps.count {
            if steps[i].operation == .pasteContent {
                // Find the most recent copy before this step
                for j in stride(from: i - 1, through: 0, by: -1) {
                    if steps[j].operation == .copyContent {
                        nodes[i].dependencies.insert(nodes[j].id)
                        break
                    }
                }
            }
        }

        return WorkflowDAG(nodes: nodes, workflow: workflow)
    }

    // MARK: - Parallel Execution

    /// Execute a workflow using the dependency DAG for parallel scheduling.
    /// Independent branches run concurrently via TaskGroup.
    static func executeParallel(
        dag: WorkflowDAG,
        parameters: [String: String] = [:],
        onProgress: (@Sendable (ParallelProgress) -> Void)? = nil
    ) async -> ParallelResult {
        var completed: Set<UUID> = []
        var failed: Set<UUID> = []
        var stepResults: [UUID: ReplayResult] = [:]
        let totalSteps = dag.nodes.count

        // Process waves: each wave contains nodes whose dependencies are all satisfied
        var wave = 0
        while completed.count + failed.count < totalSteps {
            wave += 1

            // Find ready nodes: all dependencies completed, not yet started
            let readyNodes = dag.nodes.filter { node in
                !completed.contains(node.id) &&
                !failed.contains(node.id) &&
                node.dependencies.isSubset(of: completed)
            }

            if readyNodes.isEmpty {
                // Deadlock or all failed
                break
            }

            onProgress?(ParallelProgress(
                wave: wave,
                executingSteps: readyNodes.map(\.step.description),
                completedSteps: completed.count,
                totalSteps: totalSteps
            ))

            // Execute all ready nodes in parallel
            let waveResults = await withTaskGroup(
                of: (UUID, ReplayResult).self,
                returning: [(UUID, ReplayResult)].self
            ) { group in
                for node in readyNodes {
                    group.addTask {
                        let miniWorkflow = GeneralizedWorkflow(
                            name: "step_\(node.stepIndex)",
                            description: node.step.description,
                            steps: [node.step],
                            applicability: dag.workflow.applicability
                        )
                        let result = await AdaptiveReplayEngine.shared.replay(
                            workflow: miniWorkflow,
                            parameters: parameters
                        )
                        return (node.id, result)
                    }
                }

                var results: [(UUID, ReplayResult)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            // Process wave results
            for (nodeId, result) in waveResults {
                stepResults[nodeId] = result
                if result.status == .completed {
                    completed.insert(nodeId)
                } else {
                    failed.insert(nodeId)
                }
            }
        }

        let status: ParallelResultStatus
        if failed.isEmpty && completed.count == totalSteps {
            status = .completed
        } else if !failed.isEmpty {
            status = .partialFailure
        } else {
            status = .deadlocked
        }

        return ParallelResult(
            status: status,
            completedSteps: completed.count,
            failedSteps: failed.count,
            totalSteps: totalSteps,
            waves: wave,
            stepResults: stepResults
        )
    }

    // MARK: - Analysis

    /// Analyze a workflow's parallelism potential.
    static func analyzeParallelism(workflow: GeneralizedWorkflow) -> ParallelismAnalysis {
        let dag = buildDAG(from: workflow)

        // Find the critical path (longest dependency chain)
        let criticalPathLength = findCriticalPathLength(dag)
        let maxParallelism = findMaxParallelism(dag)

        let speedupPotential: Double
        if criticalPathLength > 0 {
            speedupPotential = Double(dag.nodes.count) / Double(criticalPathLength)
        } else {
            speedupPotential = 1.0
        }

        return ParallelismAnalysis(
            totalSteps: dag.nodes.count,
            criticalPathLength: criticalPathLength,
            maxParallelBranches: maxParallelism,
            theoreticalSpeedup: speedupPotential,
            isWorthParallelizing: speedupPotential > 1.3 && maxParallelism > 1
        )
    }

    private static func findCriticalPathLength(_ dag: WorkflowDAG) -> Int {
        var memo: [UUID: Int] = [:]

        func depth(_ nodeId: UUID) -> Int {
            if let cached = memo[nodeId] { return cached }
            guard let node = dag.nodes.first(where: { $0.id == nodeId }) else { return 0 }
            let maxDep = node.dependencies.map { depth($0) }.max() ?? 0
            let result = maxDep + 1
            memo[nodeId] = result
            return result
        }

        return dag.nodes.map { depth($0.id) }.max() ?? 0
    }

    private static func findMaxParallelism(_ dag: WorkflowDAG) -> Int {
        // Count nodes at each depth level
        var depths: [UUID: Int] = [:]

        func depth(_ nodeId: UUID) -> Int {
            if let cached = depths[nodeId] { return cached }
            guard let node = dag.nodes.first(where: { $0.id == nodeId }) else { return 0 }
            let maxDep = node.dependencies.map { depth($0) }.max() ?? -1
            let result = maxDep + 1
            depths[nodeId] = result
            return result
        }

        for node in dag.nodes { _ = depth(node.id) }

        let levelCounts = Dictionary(grouping: depths.values, by: { $0 }).mapValues(\.count)
        return levelCounts.values.max() ?? 1
    }
}

// MARK: - DAG Models

struct WorkflowDAG: Sendable {
    let nodes: [DAGNode]
    let workflow: GeneralizedWorkflow
}

struct DAGNode: Sendable {
    let id: UUID
    let stepIndex: Int
    let step: AbstractStep
    var dependencies: Set<UUID>  // IDs of nodes that must complete before this one
}

// MARK: - Results

struct ParallelProgress: Sendable {
    let wave: Int
    let executingSteps: [String]
    let completedSteps: Int
    let totalSteps: Int
}

struct ParallelResult: Sendable {
    let status: ParallelResultStatus
    let completedSteps: Int
    let failedSteps: Int
    let totalSteps: Int
    let waves: Int
    let stepResults: [UUID: ReplayResult]
}

enum ParallelResultStatus: String, Sendable {
    case completed, partialFailure, deadlocked
}

struct ParallelismAnalysis: Sendable {
    let totalSteps: Int
    let criticalPathLength: Int
    let maxParallelBranches: Int
    let theoreticalSpeedup: Double
    let isWorthParallelizing: Bool

    var summary: String {
        if isWorthParallelizing {
            return "\(totalSteps) steps, \(maxParallelBranches) parallel branches, ~\(String(format: "%.1f", theoreticalSpeedup))x speedup potential"
        }
        return "\(totalSteps) steps — sequential execution recommended"
    }
}
