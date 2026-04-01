import Foundation
import os

/// Maps Executer workloads to proper QoS classes for Apple Silicon P-core/E-core scheduling.
enum WorkloadClass: String {
    case ui          // Main thread, .userInteractive — P-cores
    case routing     // <10ms classification, .userInitiated — P-cores
    case toolExec    // Tool execution, .userInitiated — P-cores
    case llmNetwork  // API calls, .userInitiated
    case embedding   // NLEmbedding / vector math, .utility — E-cores OK
    case learning    // Pattern extraction, .utility — E-cores
    case background  // File monitoring, clipboard, cache cleanup — .background

    var qos: DispatchQoS.QoSClass {
        switch self {
        case .ui:         return .userInteractive
        case .routing:    return .userInitiated
        case .toolExec:   return .userInitiated
        case .llmNetwork: return .userInitiated
        case .embedding:  return .utility
        case .learning:   return .utility
        case .background: return .background
        }
    }

    var taskPriority: TaskPriority {
        switch self {
        case .ui:         return .userInitiated
        case .routing:    return .userInitiated
        case .toolExec:   return .medium
        case .llmNetwork: return .medium
        case .embedding:  return .utility
        case .learning:   return .low
        case .background: return .background
        }
    }
}

enum ExecuterTaskScheduler {
    private static let queues: [WorkloadClass: DispatchQueue] = {
        var q: [WorkloadClass: DispatchQueue] = [:]
        for wl in [WorkloadClass.ui, .routing, .toolExec, .llmNetwork, .embedding, .learning, .background] {
            q[wl] = DispatchQueue.global(qos: wl.qos)
        }
        return q
    }()

    /// Dispatch an async closure on the appropriate QoS queue.
    @discardableResult
    static func dispatch(_ workload: WorkloadClass, work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task(priority: workload.taskPriority) {
            await work()
        }
    }

    /// Get the DispatchQueue for a given workload class.
    static func queue(for workload: WorkloadClass) -> DispatchQueue {
        queues[workload] ?? .global()
    }
}
