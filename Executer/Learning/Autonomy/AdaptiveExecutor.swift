import Foundation

/// Adapts execution when UI doesn't match expectations.
/// Falls back to text-based element finding when position-based fails.
enum AdaptiveExecutor {

    /// Attempt to find an element adaptively.
    static func findElement(description: String) -> String? {
        guard let snapshot = ScreenReader.readFrontmostApp() else { return nil }

        let lower = description.lowercased()

        // Exact title match
        if let el = snapshot.elements.first(where: { $0.title.lowercased() == lower }) {
            return el.title
        }

        // Partial title match
        if let el = snapshot.elements.first(where: { $0.title.lowercased().contains(lower) }) {
            return el.title
        }

        // Description match
        if let el = snapshot.elements.first(where: { $0.description.lowercased().contains(lower) }) {
            return el.description
        }

        // Label match
        if let el = snapshot.elements.first(where: { $0.label.lowercased().contains(lower) }) {
            return el.label
        }

        return nil
    }
}
