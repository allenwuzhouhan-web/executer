import Foundation

/// Errors that can occur in the Learning module.
enum LearningError: LocalizedError {
    case databaseNotInitialized
    case databaseOpenFailed(String)
    case schemaCreationFailed(String)
    case migrationFailed(String)
    case insertFailed(String)
    case queryFailed(String)
    case observerCreationFailed(pid_t, String)
    case accessibilityNotGranted
    case patternExtractionFailed(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "[Learning] Database not initialized"
        case .databaseOpenFailed(let path):
            return "[Learning] Failed to open database at \(path)"
        case .schemaCreationFailed(let detail):
            return "[Learning] Schema creation failed: \(detail)"
        case .migrationFailed(let detail):
            return "[Learning] Migration failed: \(detail)"
        case .insertFailed(let detail):
            return "[Learning] Insert failed: \(detail)"
        case .queryFailed(let detail):
            return "[Learning] Query failed: \(detail)"
        case .observerCreationFailed(let pid, let app):
            return "[Learning] Failed to create observer for \(app) (pid \(pid))"
        case .accessibilityNotGranted:
            return "[Learning] Accessibility permission not granted"
        case .patternExtractionFailed(let detail):
            return "[Learning] Pattern extraction failed: \(detail)"
        case .invalidConfiguration(let detail):
            return "[Learning] Invalid configuration: \(detail)"
        }
    }
}
