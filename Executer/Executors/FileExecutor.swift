import Cocoa

struct FindFilesTool: ToolDefinition {
    let name = "find_files"
    let description = "Search for files by name. Uses a pre-built index for instant results across Documents, Desktop, and Downloads. The user's main files are in ~/Documents/works (usually the G8 subfolder)."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "The filename or partial name to search for. Can use multiple words, e.g. 'ESL Q3 proposal'"),
            "limit": JSONSchema.integer(description: "Maximum number of results (default 10)", minimum: 1, maximum: 50)
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let limit = optionalInt("limit", from: args) ?? 10

        // Use the pre-built in-memory index (instant)
        let results = FileIndex.shared.search(query: query, limit: limit)

        if !results.isEmpty {
            let lines = results.map { file in
                let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
                return "\(file.path) (\(size))"
            }
            return "Found \(results.count) file(s):\n\(lines.joined(separator: "\n"))"
        }

        // Fallback: if index isn't ready yet, do a quick targeted search
        if !FileIndex.shared.isReady {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let safeQuery = query.replacingOccurrences(of: "\"", with: "\\\"")
            let result = try ShellRunner.run(
                "find \"\(home)/Documents/works\" -maxdepth 8 -iname \"*\(safeQuery)*\" -not -path '*/.*' 2>/dev/null | head -\(limit)",
                timeout: 10
            )
            if !result.output.isEmpty {
                return "Found files:\n\(result.output)"
            }
        }

        return "No files found matching '\(query)'. Try different keywords or check the filename."
    }
}

struct OpenFileTool: ToolDefinition {
    let name = "open_file"
    let description = "Open a file with its default application"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "The full path to the file")
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.open(url)
        return "Opened \(url.lastPathComponent)."
    }
}

struct OpenFileWithAppTool: ToolDefinition {
    let name = "open_file_with_app"
    let description = "Open a file with a specific application"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "The full path to the file"),
            "app_name": JSONSchema.string(description: "The name of the application to open the file with")
        ], required: ["path", "app_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let appName = try requiredString("app_name", from: args)
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try ShellRunner.run("open -a \"\(appName)\" \"\(escaped)\"")
        return "Opened \(URL(fileURLWithPath: path).lastPathComponent) with \(appName)."
    }
}

struct MoveFileTool: ToolDefinition {
    let name = "move_file"
    let description = "Move a file or folder to a new location"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "source": JSONSchema.string(description: "The current path of the file"),
            "destination": JSONSchema.string(description: "The destination path")
        ], required: ["source", "destination"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let source = try requiredString("source", from: args)
        let dest = try requiredString("destination", from: args)
        let srcURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        let dstURL = URL(fileURLWithPath: (dest as NSString).expandingTildeInPath)
        try FileManager.default.moveItem(at: srcURL, to: dstURL)
        return "Moved \(srcURL.lastPathComponent) to \(dstURL.path)."
    }
}

struct CopyFileTool: ToolDefinition {
    let name = "copy_file"
    let description = "Copy a file or folder"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "source": JSONSchema.string(description: "The path of the file to copy"),
            "destination": JSONSchema.string(description: "The destination path")
        ], required: ["source", "destination"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let source = try requiredString("source", from: args)
        let dest = try requiredString("destination", from: args)
        let srcURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        let dstURL = URL(fileURLWithPath: (dest as NSString).expandingTildeInPath)
        try FileManager.default.copyItem(at: srcURL, to: dstURL)
        return "Copied \(srcURL.lastPathComponent) to \(dstURL.path)."
    }
}

struct TrashFileTool: ToolDefinition {
    let name = "trash_file"
    let description = "Move a file to the Trash"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "The path of the file to trash")
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        return "Moved \(url.lastPathComponent) to Trash."
    }
}

struct CreateFolderTool: ToolDefinition {
    let name = "create_folder"
    let description = "Create a new folder"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "The path where the folder should be created")
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return "Created folder: \(url.path)"
    }
}

struct GetFileInfoTool: ToolDefinition {
    let name = "get_file_info"
    let description = "Get information about a file (size, dates, type)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "The path to the file")
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let attrs = try FileManager.default.attributesOfItem(atPath: (path as NSString).expandingTildeInPath)
        let size = attrs[.size] as? UInt64 ?? 0
        let created = attrs[.creationDate] as? Date
        let modified = attrs[.modificationDate] as? Date
        let type = attrs[.type] as? FileAttributeType

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]

        var info = "File: \(URL(fileURLWithPath: path).lastPathComponent)"
        info += "\nSize: \(formatter.string(fromByteCount: Int64(size)))"
        info += "\nType: \(type == .typeDirectory ? "Folder" : "File")"
        if let created = created { info += "\nCreated: \(created)" }
        if let modified = modified { info += "\nModified: \(modified)" }
        return info
    }
}

struct RevealInFinderTool: ToolDefinition {
    let name = "reveal_in_finder"
    let description = "Show a file in Finder"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "The path to the file to reveal")
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return "Showing \(url.lastPathComponent) in Finder."
    }
}

struct GetDownloadsPathTool: ToolDefinition {
    let name = "get_downloads_path"
    let description = "Get the path to the Downloads folder"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let path = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~/Downloads"
        return "Downloads folder: \(path)"
    }
}

// MARK: - Step 6: Enhanced Finder & Batch File Operations

struct BatchRenameFilesTool: ToolDefinition {
    let name = "batch_rename_files"
    let description = "Batch rename files in a directory using regex pattern matching. Supports {n} (sequential number), {date} (YYYY-MM-DD), {ext} (original extension) placeholders in replacement."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "directory": JSONSchema.string(description: "The directory containing files to rename"),
            "pattern": JSONSchema.string(description: "Regex pattern to match filenames against"),
            "replacement": JSONSchema.string(description: "Replacement string. Supports {n}, {date}, {ext} placeholders and regex capture groups ($1, $2)"),
            "preview": JSONSchema.boolean(description: "If true (default), show what would be renamed without actually renaming")
        ], required: ["directory", "pattern", "replacement"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let directory = try requiredString("directory", from: args)
        let pattern = try requiredString("pattern", from: args)
        let replacement = try requiredString("replacement", from: args)
        let preview = optionalBool("preview", from: args) ?? true

        let dirURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: dirURL.path) else {
            throw ExecuterError.invalidArguments("Directory does not exist: \(directory)")
        }

        let contents = try fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw ExecuterError.invalidArguments("Invalid regex pattern: \(pattern)")
        }

        let dateStr = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        var renames: [(String, String)] = []
        for (index, fileURL) in contents.enumerated() {
            let filename = fileURL.lastPathComponent
            let range = NSRange(filename.startIndex..., in: filename)

            if regex.firstMatch(in: filename, range: range) != nil {
                var newName = regex.stringByReplacingMatches(in: filename, range: range, withTemplate: replacement)
                newName = newName.replacingOccurrences(of: "{n}", with: String(format: "%03d", index + 1))
                newName = newName.replacingOccurrences(of: "{date}", with: dateStr)
                newName = newName.replacingOccurrences(of: "{ext}", with: fileURL.pathExtension)
                renames.append((filename, newName))
            }
        }

        if renames.isEmpty {
            return "No files matched pattern '\(pattern)' in \(directory)."
        }

        if preview {
            let lines = renames.map { "  \($0.0) → \($0.1)" }
            return "Preview (\(renames.count) files would be renamed):\n\(lines.joined(separator: "\n"))\n\nSet preview=false to apply."
        }

        var renamed = 0
        for (oldName, newName) in renames {
            let oldURL = dirURL.appendingPathComponent(oldName)
            let newURL = dirURL.appendingPathComponent(newName)
            try fm.moveItem(at: oldURL, to: newURL)
            renamed += 1
        }

        return "Renamed \(renamed) files in \(directory)."
    }
}

struct FindFilesByAgeTool: ToolDefinition {
    let name = "find_files_by_age"
    let description = "Find files by age and/or size criteria"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Directory to search in"),
            "older_than_days": JSONSchema.integer(description: "Find files older than N days", minimum: 1, maximum: nil),
            "newer_than_days": JSONSchema.integer(description: "Find files newer than N days", minimum: 1, maximum: nil),
            "min_size_mb": JSONSchema.integer(description: "Minimum file size in MB", minimum: 0, maximum: nil),
            "max_size_mb": JSONSchema.integer(description: "Maximum file size in MB", minimum: 0, maximum: nil),
            "limit": JSONSchema.integer(description: "Maximum results (default 20)", minimum: 1, maximum: 100)
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let limit = optionalInt("limit", from: args) ?? 20

        let expandedPath = (path as NSString).expandingTildeInPath

        var findArgs = "find \"\(expandedPath)\" -maxdepth 3 -type f"
        if let older = optionalInt("older_than_days", from: args) {
            findArgs += " -mtime +\(older)"
        }
        if let newer = optionalInt("newer_than_days", from: args) {
            findArgs += " -mtime -\(newer)"
        }
        if let minSize = optionalInt("min_size_mb", from: args) {
            findArgs += " -size +\(minSize)m"
        }
        if let maxSize = optionalInt("max_size_mb", from: args) {
            findArgs += " -size -\(maxSize)m"
        }
        findArgs += " 2>/dev/null | head -\(limit)"

        let result = try ShellRunner.run(findArgs, timeout: 15)
        if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No files found matching criteria in \(path)."
        }

        // Get sizes for each file
        let files = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var lines: [String] = []
        for file in files {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file) {
                let size = attrs[.size] as? UInt64 ?? 0
                let formatter = ByteCountFormatter()
                let sizeStr = formatter.string(fromByteCount: Int64(size))
                let modified = attrs[.modificationDate] as? Date
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMM d, yyyy"
                let dateStr = modified.map { dateFormatter.string(from: $0) } ?? "unknown"
                lines.append("  \(sizeStr)\t\(dateStr)\t\(file)")
            }
        }

        return "Found \(files.count) files:\n\(lines.joined(separator: "\n"))"
    }
}

struct GetFinderWindowPathTool: ToolDefinition {
    let name = "get_finder_window_path"
    let description = "Get the POSIX path of the frontmost Finder window's current directory"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let script = "tell application \"Finder\" to get POSIX path of (target of front Finder window as alias)"
        guard let path = AppleScriptRunner.run(script) else {
            return "No Finder window is open."
        }
        return "Finder window path: \(path)"
    }
}
