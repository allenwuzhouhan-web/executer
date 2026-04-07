import Foundation

/// Scans ~/Documents/works/ to bootstrap/update the Project Mind Map.
enum ProjectScanner {
    static func scan() -> [ProjectNode] {
        let fm = FileManager.default
        let worksPath = NSHomeDirectory() + "/Documents/works"
        guard fm.fileExists(atPath: worksPath),
              let topLevel = try? fm.contentsOfDirectory(atPath: worksPath) else { return [] }

        var projects: [ProjectNode] = []
        for entry in topLevel {
            let fullPath = worksPath + "/" + entry
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue, !entry.hasPrefix(".") else { continue }

            if entry == "G8" {
                if let subjects = try? fm.contentsOfDirectory(atPath: fullPath) {
                    for subject in subjects {
                        let subjectPath = fullPath + "/" + subject
                        var subIsDir: ObjCBool = false
                        guard fm.fileExists(atPath: subjectPath, isDirectory: &subIsDir), subIsDir.boolValue, !subject.hasPrefix(".") else { continue }
                        var node = ProjectNode(name: "G8 — \(subject)", rootPath: subjectPath, tags: ["school", "G8", subject.lowercased()])
                        node.files = discoverFiles(in: subjectPath, maxDepth: 3)
                        node.lastActivity = latestModification(in: node.files)
                        projects.append(node)
                    }
                }
            } else {
                var node = ProjectNode(name: entry, rootPath: fullPath)
                node.files = discoverFiles(in: fullPath, maxDepth: 3)
                node.lastActivity = latestModification(in: node.files)
                projects.append(node)
            }
        }
        return projects
    }

    private static func discoverFiles(in path: String, maxDepth: Int) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        func walk(_ dir: String, depth: Int) {
            guard depth < maxDepth, let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries where !entry.hasPrefix(".") {
                let full = dir + "/" + entry
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue { walk(full, depth: depth + 1) } else { results.append(full) }
            }
        }
        walk(path, depth: 0)
        return results
    }

    private static func latestModification(in files: [String]) -> Date {
        let fm = FileManager.default
        var latest = Date.distantPast
        for file in files {
            if let attrs = try? fm.attributesOfItem(atPath: file),
               let mod = attrs[.modificationDate] as? Date, mod > latest { latest = mod }
        }
        return latest == .distantPast ? Date() : latest
    }
}
