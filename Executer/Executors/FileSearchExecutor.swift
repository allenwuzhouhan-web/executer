import Foundation
import PDFKit

// MARK: - Search File Contents (grep)

struct SearchFileContentsTool: ToolDefinition {
    let name = "search_file_contents"
    let description = "Search for a text pattern in files within a directory (like grep). Returns matching lines with file paths and line numbers."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "pattern": JSONSchema.string(description: "The text pattern to search for"),
            "path": JSONSchema.string(description: "Directory to search in (use ~ for home directory)"),
            "file_types": JSONSchema.string(description: "Comma-separated file extensions to filter (e.g. 'swift,py,js'). Omit for all files."),
            "max_results": JSONSchema.integer(description: "Maximum matching lines to return (default 20)", minimum: 1, maximum: 100),
            "case_sensitive": JSONSchema.boolean(description: "Case-sensitive search (default false)"),
        ], required: ["pattern", "path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let pattern = try requiredString("pattern", from: args)
        let rawPath = try requiredString("path", from: args)
        let fileTypes = optionalString("file_types", from: args)
        let maxResults = optionalInt("max_results", from: args) ?? 20
        let caseSensitive = optionalBool("case_sensitive", from: args) ?? false

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        // Shell-escape the pattern (single quotes with escaping)
        let escaped = pattern.replacingOccurrences(of: "'", with: "'\\''")

        var cmd = "grep -rn"
        if !caseSensitive { cmd += " -i" }

        // Add file type filters
        if let types = fileTypes {
            for ext in types.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                cmd += " --include='*.\(ext)'"
            }
        }

        cmd += " -- '\(escaped)' '\(path)' | head -\(maxResults)"

        let result = try ShellRunner.run(cmd, timeout: 15)

        if result.output.isEmpty {
            return "No matches found for '\(pattern)' in \(path)."
        }
        return "Search results for '\(pattern)':\n\(result.output)"
    }
}

// MARK: - Read PDF Text

struct ReadPDFTextTool: ToolDefinition {
    let name = "read_pdf_text"
    let description = "Extract text content from a PDF file."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the PDF file (use ~ for home directory)"),
            "pages": JSONSchema.string(description: "Page range to read (e.g. '1-5', '3', '10-20'). Omit for all pages."),
            "max_length": JSONSchema.integer(description: "Maximum characters to return (default 5000)", minimum: 100, maximum: 30000),
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let pagesStr = optionalString("pages", from: args)
        let maxLength = optionalInt("max_length", from: args) ?? 5000

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        // Check file size (50MB limit for PDFs)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = attrs[.size] as? UInt64 ?? 0
        if size > 50_000_000 {
            return "PDF too large (\(size / 1_000_000)MB). Max 50MB."
        }

        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else {
            return "Could not open PDF: \(path)"
        }

        let pageCount = document.pageCount
        if pageCount > 50 && pagesStr == nil {
            return "PDF has \(pageCount) pages. Please specify a page range (e.g. pages: '1-10')."
        }

        // Parse page range
        var startPage = 0
        var endPage = pageCount - 1

        if let pagesStr = pagesStr {
            let parts = pagesStr.components(separatedBy: "-")
            if parts.count == 2, let s = Int(parts[0]), let e = Int(parts[1]) {
                startPage = max(s - 1, 0)
                endPage = min(e - 1, pageCount - 1)
            } else if let single = Int(pagesStr) {
                startPage = max(single - 1, 0)
                endPage = startPage
            }
        }

        var text = ""
        for i in startPage...endPage {
            guard let page = document.page(at: i) else { continue }
            if let pageText = page.string {
                text += "--- Page \(i + 1) ---\n\(pageText)\n\n"
            }
        }

        if text.isEmpty {
            return "No text content found in PDF (may be image-based)."
        }

        let truncated = text.count > maxLength ? String(text.prefix(maxLength)) + "\n... (truncated)" : text
        return "PDF: \(path) (\(pageCount) pages)\n\n\(truncated)"
    }
}

// MARK: - Directory Tree

struct DirectoryTreeTool: ToolDefinition {
    let name = "directory_tree"
    let description = "Show directory structure as a visual tree. Use for understanding folder hierarchy. For a flat file listing with details (size, date), use list_directory instead."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the directory (use ~ for home directory)"),
            "max_depth": JSONSchema.integer(description: "Maximum depth to traverse (default 3, max 5)", minimum: 1, maximum: 5),
            "show_hidden": JSONSchema.boolean(description: "Show hidden files (default false)"),
            "max_entries": JSONSchema.integer(description: "Maximum total entries to show (default 200)", minimum: 1, maximum: 500),
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let maxDepth = min(optionalInt("max_depth", from: args) ?? 3, 5)
        let showHidden = optionalBool("show_hidden", from: args) ?? false
        let maxEntries = optionalInt("max_entries", from: args) ?? 200

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        var count = 0
        var result = "\(path)\n"

        func buildTree(dirPath: String, prefix: String, depth: Int) {
            guard depth < maxDepth, count < maxEntries else { return }

            let url = URL(fileURLWithPath: dirPath)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { return }

            var items = contents.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
            if !showHidden {
                items = items.filter { !$0.lastPathComponent.hasPrefix(".") }
            }

            for (i, item) in items.enumerated() {
                guard count < maxEntries else {
                    result += "\(prefix)... (truncated)\n"
                    return
                }

                let isLast = i == items.count - 1
                let connector = isLast ? "└── " : "├── "
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let name = isDir ? "\(item.lastPathComponent)/" : item.lastPathComponent

                result += "\(prefix)\(connector)\(name)\n"
                count += 1

                if isDir {
                    let childPrefix = prefix + (isLast ? "    " : "│   ")
                    buildTree(dirPath: item.path, prefix: childPrefix, depth: depth + 1)
                }
            }
        }

        buildTree(dirPath: path, prefix: "", depth: 0)
        return result
    }
}

// MARK: - File Preview

struct FilePreviewTool: ToolDefinition {
    let name = "file_preview"
    let description = "Quick preview of a file: shows metadata (size, type, modified date) and the first N lines of content."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the file (use ~ for home directory)"),
            "lines": JSONSchema.integer(description: "Number of lines to preview (default 30)", minimum: 1, maximum: 100),
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let lines = optionalInt("lines", from: args) ?? 30

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        guard FileManager.default.fileExists(atPath: path) else {
            return "File not found: \(path)"
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = attrs[.size] as? UInt64 ?? 0
        let modified = attrs[.modificationDate] as? Date
        let fileType = (path as NSString).pathExtension

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let modStr = modified.map { formatter.string(from: $0) } ?? "unknown"

        var result = """
        File: \(path)
        Type: \(fileType.isEmpty ? "unknown" : fileType)
        Size: \(formatSize(size))
        Modified: \(modStr)
        """

        if PathSecurity.isBinary(path) {
            result += "\n\n(Binary file — cannot preview content)"
        } else if size <= PathSecurity.maxFileSize {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let allLines = content.components(separatedBy: "\n")
            let preview = allLines.prefix(lines)
            result += "\n\n--- Content (first \(preview.count) of \(allLines.count) lines) ---\n"
            for (i, line) in preview.enumerated() {
                result += "\(i + 1): \(line)\n"
            }
        } else {
            result += "\n\n(File too large to preview — use read_file with offset/max_lines)"
        }

        return result
    }

    private func formatSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
