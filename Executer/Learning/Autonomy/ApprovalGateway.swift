import Foundation

/// Manages approval requests for autonomous workflow execution.
final class ApprovalGateway {
    static let shared = ApprovalGateway()

    /// Callback for requesting user approval. Set by AppState.
    var approvalHandler: ((String, @escaping (Bool) -> Void) -> Void)?

    private init() {}

    /// Request approval for a workflow execution.
    func requestApproval(description: String, completion: @escaping (Bool) -> Void) {
        if let handler = approvalHandler {
            handler(description, completion)
        } else {
            // No handler set — deny by default
            completion(false)
        }
    }

    /// Request approval with async/await.
    func requestApproval(description: String) async -> Bool {
        await withCheckedContinuation { continuation in
            requestApproval(description: description) { approved in
                continuation.resume(returning: approved)
            }
        }
    }
}
