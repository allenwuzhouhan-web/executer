import Foundation

/// An actively managed goal with sub-goals and state tracking.
struct ManagedGoal: Codable, Identifiable {
    let id: UUID
    var title: String
    var description: String
    var subGoals: [SubGoal]
    var state: GoalState
    var priority: Double           // 0.0-1.0
    var createdAt: Date
    var updatedAt: Date
    var deadline: Date?
    var source: GoalSource
    var failureHistory: [FailureRecord]

    enum GoalState: String, Codable {
        case pending
        case active
        case blocked
        case completed
        case failed
    }

    enum GoalSource: String, Codable {
        case explicit    // User said "prepare Monday presentation"
        case detected    // Agent inferred from conversation
        case passive     // Imported from GoalTracker observation
    }

    struct SubGoal: Codable, Identifiable {
        let id: UUID
        var title: String
        var state: GoalState
        var dependencies: [UUID]  // IDs of sub-goals this depends on
        var toolHints: [String]   // Tools likely needed
        var result: String?       // Output when completed
        var failureReason: String?
    }

    struct FailureRecord: Codable {
        let subGoalId: UUID
        let failureReason: String
        let attemptedAt: Date
        let alternativeUsed: String?
    }

    /// Returns the next sub-goal that is ready to execute (dependencies met, state is pending).
    func nextActionableSubGoal() -> SubGoal? {
        actionableSubGoals().first
    }

    /// Returns ALL sub-goals ready to execute in parallel (dependencies met, state is pending).
    func actionableSubGoals() -> [SubGoal] {
        let completedIds = Set(subGoals.filter { $0.state == .completed }.map(\.id))
        return subGoals.filter { sub in
            sub.state == .pending && sub.dependencies.allSatisfy { completedIds.contains($0) }
        }
    }

    /// Validates the dependency graph has no cycles. Returns true if valid.
    func validateDependencies() -> Bool {
        // Topological sort via Kahn's algorithm
        let ids = Set(subGoals.map(\.id))
        var inDegree: [UUID: Int] = [:]
        var adjacency: [UUID: [UUID]] = [:]
        for sub in subGoals {
            inDegree[sub.id] = sub.dependencies.count
            for dep in sub.dependencies {
                adjacency[dep, default: []].append(sub.id)
            }
        }
        var queue = subGoals.filter { $0.dependencies.isEmpty }.map(\.id)
        var visited = 0
        while !queue.isEmpty {
            let current = queue.removeFirst()
            visited += 1
            for neighbor in adjacency[current] ?? [] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }
        return visited == ids.count
    }

    /// Overall progress percentage.
    var progress: Double {
        guard !subGoals.isEmpty else { return 0 }
        return Double(subGoals.filter { $0.state == .completed }.count) / Double(subGoals.count)
    }
}
