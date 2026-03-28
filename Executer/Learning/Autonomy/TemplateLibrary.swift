import Foundation

/// CRUD for workflow templates with natural language trigger matching.
final class TemplateLibrary {
    static let shared = TemplateLibrary()

    private(set) var templates: [WorkflowTemplate] = []
    private let lock = NSLock()

    private init() {
        loadTemplates()
    }

    /// Find a template by name or trigger phrase.
    func find(matching query: String) -> WorkflowTemplate? {
        lock.lock()
        defer { lock.unlock() }
        let lower = query.lowercased()
        return templates.first { t in
            t.name.lowercased().contains(lower) ||
            (t.triggerPhrase?.lowercased().contains(lower) ?? false)
        }
    }

    /// Add or update a template.
    func save(_ template: WorkflowTemplate) {
        lock.lock()
        if let idx = templates.firstIndex(where: { $0.id == template.id }) {
            templates[idx] = template
        } else {
            templates.append(template)
        }
        lock.unlock()
        persistTemplates()
    }

    /// Remove a template.
    func remove(id: UUID) {
        lock.lock()
        templates.removeAll { $0.id == id }
        lock.unlock()
        persistTemplates()
    }

    /// List all templates.
    func all() -> [WorkflowTemplate] {
        lock.lock()
        defer { lock.unlock() }
        return templates
    }

    // MARK: - Persistence

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Executer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workflow_templates.json")
    }

    private func loadTemplates() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([WorkflowTemplate].self, from: data) else { return }
        templates = loaded
    }

    private func persistTemplates() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
