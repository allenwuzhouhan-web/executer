import Foundation

/// Persistent knowledge graph of the user's projects.
actor ProjectMindMap {
    static let shared = ProjectMindMap()
    private var projects: [ProjectNode] = []
    private var projectIndex: [UUID: Int] = [:]

    private static var _cachedPromptSection: String = ""
    private static let promptLock = NSLock()
    static var promptSection: String {
        promptLock.lock()
        defer { promptLock.unlock() }
        return _cachedPromptSection
    }

    private static var storageURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Executer", isDirectory: true).appendingPathComponent("project_mind_map.json")
    }

    init() {
        projects = Self.loadFromDisk()
        rebuildIndex()
        Self.promptLock.lock()
        Self._cachedPromptSection = buildPromptSection()
        Self.promptLock.unlock()
    }

    func allProjects() -> [ProjectNode] { projects }
    func activeProjects() -> [ProjectNode] { projects.filter { $0.completionEstimate < 1.0 }.sorted { $0.lastActivity > $1.lastActivity } }
    func project(id: UUID) -> ProjectNode? { guard let idx = projectIndex[id] else { return nil }; return projects[idx] }
    func project(named name: String) -> ProjectNode? { projects.first { $0.name.lowercased() == name.lowercased() } }
    func projectsForFile(_ path: String) -> [ProjectNode] { projects.filter { $0.files.contains(path) || path.hasPrefix($0.rootPath ?? "///") } }

    @discardableResult
    func addProject(_ project: ProjectNode) -> ProjectNode {
        guard !projects.contains(where: { $0.name.lowercased() == project.name.lowercased() }) else {
            return projects.first { $0.name.lowercased() == project.name.lowercased() }!
        }
        projects.append(project); rebuildIndex(); save(); return project
    }

    func updateProject(id: UUID, update: (inout ProjectNode) -> Void) {
        guard let idx = projectIndex[id] else { return }
        update(&projects[idx]); projects[idx].lastActivity = Date(); save()
    }

    func linkFile(_ path: String, toProject id: UUID) {
        guard let idx = projectIndex[id] else { return }
        if !projects[idx].files.contains(path) { projects[idx].files.append(path); projects[idx].lastActivity = Date(); save() }
    }

    func linkGoal(_ goalId: UUID, toProject id: UUID) {
        guard let idx = projectIndex[id] else { return }
        if !projects[idx].goalIds.contains(goalId) { projects[idx].goalIds.append(goalId); save() }
    }

    func removeProject(id: UUID) { projects.removeAll { $0.id == id }; rebuildIndex(); save() }

    func handleFileEvent(path: String) {
        for i in projects.indices {
            if let root = projects[i].rootPath, path.hasPrefix(root) {
                projects[i].lastActivity = Date()
                if !projects[i].files.contains(path) { projects[i].files.append(path) }
            }
        }
    }

    func handleRadarSignal(projectId: UUID, signalTitle: String, urgency: Double) {
        guard let idx = projectIndex[projectId] else { return }
        projects[idx].lastActivity = Date(); save()
    }

    func refreshFromDisk() {
        let scanned = ProjectScanner.scan()
        for discovered in scanned {
            if let existing = projects.first(where: { $0.name.lowercased() == discovered.name.lowercased() }) {
                if let idx = projectIndex[existing.id] {
                    let newFiles = discovered.files.filter { !projects[idx].files.contains($0) }
                    projects[idx].files.append(contentsOf: newFiles)
                    if discovered.lastActivity > projects[idx].lastActivity { projects[idx].lastActivity = discovered.lastActivity }
                }
            } else { projects.append(discovered) }
        }
        rebuildIndex(); save()
        print("[ProjectMindMap] Refreshed: \(projects.count) projects total")
    }

    private func buildPromptSection() -> String {
        let active = projects.filter { $0.completionEstimate < 1.0 }.sorted { $0.lastActivity > $1.lastActivity }.prefix(8)
        guard !active.isEmpty else { return "" }
        var section = "\n\n## Active Projects\n"
        for p in active {
            let age = Int(-p.lastActivity.timeIntervalSinceNow / 3600)
            let ageStr = age < 1 ? "just now" : (age < 24 ? "\(age)h ago" : "\(age / 24)d ago")
            section += "- **\(p.name)** (\(Int(p.completionEstimate * 100))% complete, active \(ageStr))"
            if !p.tags.isEmpty { section += " [\(p.tags.joined(separator: ", "))]" }
            section += "\n"
        }
        return section
    }

    private func rebuildIndex() { projectIndex = [:]; for (i, p) in projects.enumerated() { projectIndex[p.id] = i } }

    private func save() {
        Self.promptLock.lock(); Self._cachedPromptSection = buildPromptSection(); Self.promptLock.unlock()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(projects) else { return }
        let dir = Self.storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    private static func loadFromDisk() -> [ProjectNode] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ProjectNode].self, from: data)) ?? []
    }
}

// MARK: - Tools
struct ListProjectsTool: ToolDefinition {
    let name = "list_projects"
    let description = "List all tracked projects with their status, completion percentage, and recent activity."
    var parameters: [String: Any] { JSONSchema.object(properties: ["active_only": JSONSchema.boolean(description: "If true, only show incomplete projects (default true)")], required: []) }
    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let activeOnly = optionalBool("active_only", from: args) ?? true
        let projects = activeOnly ? await ProjectMindMap.shared.activeProjects() : await ProjectMindMap.shared.allProjects()
        guard !projects.isEmpty else { return "No projects found." }
        let formatter = DateFormatter(); formatter.dateStyle = .medium
        var result = "Projects (\(projects.count)):\n"
        for p in projects { result += "\n**\(p.name)** — \(Int(p.completionEstimate * 100))% complete, \(p.files.count) files, active: \(formatter.string(from: p.lastActivity))" }
        return result
    }
}

struct GetProjectTool: ToolDefinition {
    let name = "get_project"
    let description = "Get detailed info about a specific project by name."
    var parameters: [String: Any] { JSONSchema.object(properties: ["name": JSONSchema.string(description: "Project name")], required: ["name"]) }
    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let name = try requiredString("name", from: args)
        guard let p = await ProjectMindMap.shared.project(named: name) else { return "Project '\(name)' not found." }
        var result = "**\(p.name)** — \(Int(p.completionEstimate * 100))% complete\nFiles: \(p.files.count)\n"
        if let root = p.rootPath { result += "Root: \(root)\n" }
        if !p.tags.isEmpty { result += "Tags: \(p.tags.joined(separator: ", "))\n" }
        return result
    }
}

struct UpdateProjectTool: ToolDefinition {
    let name = "update_project"
    let description = "Update a project's completion, tags, or deadlines."
    var parameters: [String: Any] { JSONSchema.object(properties: ["name": JSONSchema.string(description: "Project name"), "completion": JSONSchema.number(description: "0.0–1.0"), "add_tag": JSONSchema.string(description: "Tag to add")], required: ["name"]) }
    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let name = try requiredString("name", from: args)
        guard let p = await ProjectMindMap.shared.project(named: name) else { return "Not found." }
        await ProjectMindMap.shared.updateProject(id: p.id) { proj in
            if let c = args["completion"] as? Double { proj.completionEstimate = min(1.0, max(0.0, c)) }
            if let t = args["add_tag"] as? String { proj.tags.append(t) }
        }
        return "Updated '\(name)'."
    }
}

struct LinkFileToProjectTool: ToolDefinition {
    let name = "link_file_to_project"
    let description = "Associate a file with a project."
    var parameters: [String: Any] { JSONSchema.object(properties: ["project_name": JSONSchema.string(description: "Project name"), "file_path": JSONSchema.string(description: "File path")], required: ["project_name", "file_path"]) }
    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let name = try requiredString("project_name", from: args)
        let path = try requiredString("file_path", from: args)
        guard let p = await ProjectMindMap.shared.project(named: name) else { return "Not found." }
        await ProjectMindMap.shared.linkFile(path, toProject: p.id)
        return "Linked to '\(name)'."
    }
}
