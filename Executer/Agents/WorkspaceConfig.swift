import Foundation

/// Workspace configuration for the overnight agent.
/// Knows Allen's G8 folder structure, subject routing rules, and file conventions.
class WorkspaceConfig {
    static let shared = WorkspaceConfig()

    /// The designated workspace root.
    let workspaceRoot: String = NSHomeDirectory() + "/Documents/works/G8"

    /// Downloads folder (source for file organization).
    let downloadsPath: String = NSHomeDirectory() + "/Downloads"

    /// Inbox folder for files that couldn't be auto-routed.
    var inboxPath: String { workspaceRoot + "/_Inbox" }

    /// Auto-discovered subject folders.
    private(set) var subjectFolders: [String] = []

    /// Keyword → subject routing rules.
    private(set) var routingRules: [String: String] = [:]

    private static var configURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Executer", isDirectory: true)
            .appendingPathComponent("workspace_config.json")
    }

    private init() {
        discoverSubjects()
        loadRoutingRules()
    }

    // MARK: - Subject Discovery

    /// Scan the G8 folder for subject directories.
    func discoverSubjects() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: workspaceRoot) else {
            print("[WorkspaceConfig] Cannot read workspace root: \(workspaceRoot)")
            return
        }

        subjectFolders = contents.filter { name in
            var isDir: ObjCBool = false
            let path = workspaceRoot + "/" + name
            return fm.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
                && !name.hasPrefix(".")
                && !name.hasPrefix("_")
        }.sorted()

        print("[WorkspaceConfig] Discovered \(subjectFolders.count) subject folders: \(subjectFolders.joined(separator: ", "))")
    }

    // MARK: - File Routing

    /// Route a filename to the best-matching subject folder.
    /// Returns the full destination path, or inbox path if no confident match.
    func routeFile(filename: String) -> (subject: String, path: String, confidence: Double) {
        let lower = filename.lowercased()

        // Check routing rules (keyword matching)
        var bestMatch: (subject: String, score: Int) = ("", 0)

        for (keyword, subject) in routingRules {
            if lower.contains(keyword.lowercased()) {
                let score = keyword.count  // Longer keyword = more specific = higher score
                if score > bestMatch.score {
                    bestMatch = (subject, score)
                }
            }
        }

        if !bestMatch.subject.isEmpty {
            let confidence = min(Double(bestMatch.score) / 10.0, 0.95)
            return (bestMatch.subject, workspaceRoot + "/" + bestMatch.subject, confidence)
        }

        // No match — route to inbox
        return ("_Inbox", inboxPath, 0.0)
    }

    /// Check if a path is within the designated workspace.
    func isInWorkspace(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix(workspaceRoot) || expanded.hasPrefix(inboxPath)
    }

    /// Check if a path is in Downloads (allowed as source for file org).
    func isInDownloads(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix(downloadsPath)
    }

    // MARK: - Routing Rules

    private func loadRoutingRules() {
        // Load custom rules from disk
        if let data = try? Data(contentsOf: Self.configURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            routingRules = saved
        }

        // Merge with defaults (don't overwrite user customizations)
        for (keyword, subject) in Self.defaultRules {
            if routingRules[keyword] == nil {
                routingRules[keyword] = subject
            }
        }

        // Ensure all rules point to existing subjects
        let validSubjects = Set(subjectFolders)
        routingRules = routingRules.filter { validSubjects.contains($0.value) || $0.value == "_Inbox" }

        saveRoutingRules()
    }

    func saveRoutingRules() {
        if let data = try? JSONEncoder().encode(routingRules) {
            try? data.write(to: Self.configURL, options: .atomic)
        }
    }

    /// Add or update a routing rule (learned from user behavior).
    func learnRoute(keyword: String, subject: String) {
        routingRules[keyword.lowercased()] = subject
        saveRoutingRules()
        print("[WorkspaceConfig] Learned routing: '\(keyword)' → \(subject)")
    }

    // MARK: - Default Rules

    private static let defaultRules: [String: String] = [
        // ELA
        "literature": "ELA", "essay": "ELA", "reading": "ELA",
        "novel": "ELA", "poem": "ELA", "1984": "ELA", "gatsby": "ELA",
        "rolesheet": "ELA", "book": "ELA", "ela": "ELA",

        // Chinese
        "作文": "Chinese", "语文": "Chinese", "古诗": "Chinese",
        "阅读": "Chinese", "汉字": "Chinese", "青花": "Chinese",
        "演讲": "Chinese", "复习": "Chinese", "chinese": "Chinese",

        // ESL
        "esl": "ESL", "truth lab": "ESL", "truthlab": "ESL",
        "plagiarism": "ESL", "ielts": "ESL", "toefl": "ESL",

        // Maths
        "math": "Maths", "equation": "Maths", "calculus": "Maths",
        "precalc": "Maths", "algebra": "Maths", "geometry": "Maths",
        "ap math": "Maths", "origami": "Maths", "统计": "Maths",

        // Science
        "science": "Science", "lab": "Science", "biology": "Science",
        "chemistry": "Science", "physics": "Science", "experiment": "Science",
        "brainbee": "Science", "模拟题": "Science",

        // CS
        "python": "CS", "code": "CS", "algorithm": "CS",
        "programming": "CS", "cs ": "CS", "computer": "CS",

        // History
        "history": "History", "历史": "History", "dynasty": "History",
        "中国历史": "History",

        // Geography
        "geography": "Geography", "map": "Geography", "地理": "Geography",

        // Social Studies
        "social": "Social Studies", "society": "Social Studies",
        "politics": "Social Studies", "government": "Social Studies",

        // Art & Music
        "art": "Art & Music", "music": "Art & Music", "violin": "Art & Music",
        "drawing": "Art & Music", "design": "Art & Music", "video": "Art & Music",

        // Morality
        "morality": "Morality & Law", "道德": "Morality & Law", "法治": "Morality & Law",

        // Holiday
        "holiday": "Holiday Homework", "假期": "Holiday Homework",
    ]

    // MARK: - Junk File Detection

    /// Files that are safe to clean up.
    static let junkPatterns: [String] = [
        ".DS_Store",            // macOS system files
        "~$",                   // Word lock files (prefix)
        ".localized",           // macOS localization
        "Thumbs.db",            // Windows thumbnails
        "desktop.ini",          // Windows config
    ]

    /// Check if a filename is system junk that can be safely deleted.
    static func isJunkFile(_ filename: String) -> Bool {
        for pattern in junkPatterns {
            if filename == pattern || filename.hasPrefix(pattern) { return true }
        }
        return false
    }

    /// School document extensions that should be organized.
    static let schoolDocExtensions: Set<String> = [
        "pdf", "docx", "doc", "pptx", "ppt", "xlsx", "xls",
        "txt", "md", "epub", "rtf", "csv", "pages", "numbers", "key"
    ]
}
