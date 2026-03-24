import Foundation

// MARK: - Read File

struct ReadFileTool: ToolDefinition {
    let name = "read_file"
    let description = "Read the contents of a text file with line numbers. Use for viewing code, configs, notes, etc."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the file (use ~ for home directory)"),
            "max_lines": JSONSchema.integer(description: "Maximum lines to return (default 200, max 500)", minimum: 1, maximum: 500),
            "offset": JSONSchema.integer(description: "Line number to start from (0-based, default 0)", minimum: 0),
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let maxLines = min(optionalInt("max_lines", from: args) ?? 200, 500)
        let offset = optionalInt("offset", from: args) ?? 0

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        guard FileManager.default.fileExists(atPath: path) else {
            return "File not found: \(path)"
        }

        if PathSecurity.isBinary(path) {
            return "Cannot read binary file: \(path)"
        }

        // Check file size
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = attrs[.size] as? UInt64 ?? 0
        if size > PathSecurity.maxFileSize {
            return "File too large (\(size / 1024)KB). Max \(PathSecurity.maxFileSize / 1024)KB. Use offset/max_lines to read portions."
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let allLines = content.components(separatedBy: "\n")
        let totalLines = allLines.count

        let startLine = min(offset, totalLines)
        let endLine = min(startLine + maxLines, totalLines)
        let slice = allLines[startLine..<endLine]

        var result = ""
        for (i, line) in slice.enumerated() {
            let lineNum = startLine + i + 1
            result += "\(lineNum): \(line)\n"
        }

        result += "\nShowing lines \(startLine + 1)-\(endLine) of \(totalLines) total."
        return result
    }
}

// MARK: - Write File

struct WriteFileTool: ToolDefinition {
    let name = "write_file"
    let description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the file (use ~ for home directory)"),
            "content": JSONSchema.string(description: "The content to write"),
            "create_directories": JSONSchema.boolean(description: "Create parent directories if they don't exist (default false)"),
        ], required: ["path", "content"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let content = try requiredString("content", from: args)
        let createDirs = optionalBool("create_directories", from: args) ?? false

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        // Limit content size
        guard content.utf8.count <= 100_000 else {
            return "Content too large (\(content.utf8.count / 1024)KB). Max 100KB."
        }

        if createDirs {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return "Wrote \(content.count) characters to \(path)."
    }
}

// MARK: - Edit File

struct EditFileTool: ToolDefinition {
    let name = "edit_file"
    let description = "Edit a text file by replacing, inserting, or deleting lines. Use read_file first to see current content."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the file"),
            "operation": JSONSchema.enumString(description: "The edit operation", values: ["replace", "insert", "delete"]),
            "line_start": JSONSchema.integer(description: "Starting line number (1-based)", minimum: 1),
            "line_end": JSONSchema.integer(description: "Ending line number (1-based, inclusive). For replace/delete. Defaults to line_start.", minimum: 1),
            "new_content": JSONSchema.string(description: "New content to insert or replace with. Required for replace/insert."),
        ], required: ["path", "operation", "line_start"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let operation = try requiredString("operation", from: args)
        let lineStart = optionalInt("line_start", from: args) ?? 1
        let lineEnd = optionalInt("line_end", from: args) ?? lineStart
        let newContent = optionalString("new_content", from: args)

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        guard FileManager.default.fileExists(atPath: path) else {
            return "File not found: \(path)"
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")

        let startIdx = max(lineStart - 1, 0)
        let endIdx = min(lineEnd - 1, lines.count - 1)

        switch operation {
        case "replace":
            guard let newContent = newContent else {
                return "new_content is required for replace operation."
            }
            let newLines = newContent.components(separatedBy: "\n")
            lines.replaceSubrange(startIdx...endIdx, with: newLines)

        case "insert":
            guard let newContent = newContent else {
                return "new_content is required for insert operation."
            }
            let newLines = newContent.components(separatedBy: "\n")
            lines.insert(contentsOf: newLines, at: startIdx)

        case "delete":
            guard startIdx <= endIdx, endIdx < lines.count else {
                return "Invalid line range for delete: \(lineStart)-\(lineEnd) (file has \(lines.count) lines)."
            }
            lines.removeSubrange(startIdx...endIdx)

        default:
            return "Unknown operation: \(operation). Use 'replace', 'insert', or 'delete'."
        }

        let result = lines.joined(separator: "\n")
        try result.write(toFile: path, atomically: true, encoding: .utf8)
        return "Edited \(path): \(operation) at lines \(lineStart)-\(lineEnd). File now has \(lines.count) lines."
    }
}

// MARK: - List Directory

struct ListDirectoryTool: ToolDefinition {
    let name = "list_directory"
    let description = "List files and folders in a directory with sizes and types."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the directory (use ~ for home directory)"),
            "show_hidden": JSONSchema.boolean(description: "Show hidden files (default false)"),
            "max_entries": JSONSchema.integer(description: "Maximum entries to return (default 100)", minimum: 1, maximum: 500),
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let showHidden = optionalBool("show_hidden", from: args) ?? false
        let maxEntries = optionalInt("max_entries", from: args) ?? 100

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        } catch {
            return "Cannot list directory: \(error.localizedDescription)"
        }

        var items = contents
        if !showHidden {
            items = items.filter { !$0.lastPathComponent.hasPrefix(".") }
        }

        items.sort { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }

        var lines: [String] = ["Contents of \(path):"]
        for item in items.prefix(maxEntries) {
            let resources = try? item.resourceValues(forKeys: Set(keys))
            let isDir = resources?.isDirectory ?? false
            let size = resources?.fileSize ?? 0

            if isDir {
                lines.append("[DIR]  \(item.lastPathComponent)/")
            } else {
                let sizeStr = formatFileSize(UInt64(size))
                lines.append("[FILE] \(item.lastPathComponent) (\(sizeStr))")
            }
        }

        if items.count > maxEntries {
            lines.append("... and \(items.count - maxEntries) more entries")
        }

        lines.append("\nTotal: \(items.count) items")
        return lines.joined(separator: "\n")
    }

    private func formatFileSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Append to File

struct AppendToFileTool: ToolDefinition {
    let name = "append_to_file"
    let description = "Append content to the end of a file. Creates the file if it doesn't exist."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the file (use ~ for home directory)"),
            "content": JSONSchema.string(description: "The content to append"),
        ], required: ["path", "content"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let content = try requiredString("content", from: args)

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        let url = URL(fileURLWithPath: path)

        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            guard let data = content.data(using: .utf8) else {
                return "Failed to encode content."
            }
            handle.write(data)
        } else {
            // Create parent directory if needed
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }

        return "Appended \(content.count) characters to \(path)."
    }
}
