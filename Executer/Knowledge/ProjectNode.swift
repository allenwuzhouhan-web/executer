import Foundation

/// A node in the Project Mind Map — represents a user project with files, deadlines, people, and dependencies.
struct ProjectNode: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var files: [String]
    var deadlines: [Deadline]
    var people: [String]
    var dependencies: [UUID]
    var goalIds: [UUID]
    var completionEstimate: Double
    var lastActivity: Date
    var tags: [String]
    var rootPath: String?
    var createdAt: Date

    struct Deadline: Codable, Sendable {
        let title: String
        let date: Date
        var completed: Bool
    }

    init(name: String, rootPath: String? = nil, files: [String] = [], tags: [String] = []) {
        self.id = UUID()
        self.name = name
        self.rootPath = rootPath
        self.files = files
        self.deadlines = []
        self.people = []
        self.dependencies = []
        self.goalIds = []
        self.completionEstimate = 0.0
        self.lastActivity = Date()
        self.tags = tags
        self.createdAt = Date()
    }
}
