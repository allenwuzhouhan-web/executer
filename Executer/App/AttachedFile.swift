import Foundation

/// A file attached to the input bar for context in the user's question.
struct AttachedFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let ext: String
    let content: String  // extracted text content

    /// Supported file extensions for drag & drop
    static let supportedExtensions: Set<String> = [
        "pdf", "txt", "md", "rtf", "rtfd",
        "docx", "doc", "pages",
        "swift", "js", "ts", "py", "cpp", "c", "h", "hpp",
        "java", "go", "rs", "rb", "php", "css", "html", "xml", "json",
        "yaml", "yml", "toml", "sh", "zsh", "bash",
        "csv", "log", "tex",
    ]

    /// Create an AttachedFile by reading and extracting text from the given URL.
    static func from(url: URL) -> AttachedFile? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        guard supportedExtensions.contains(ext) else {
            print("[AttachedFile] Unsupported extension: \(ext)")
            return nil
        }

        let content: String

        if ext == "pdf" {
            content = extractPDF(url: url)
        } else if ext == "rtf" || ext == "rtfd" {
            content = extractRTF(url: url)
        } else if ext == "docx" {
            content = extractDocx(url: url)
        } else {
            // Plain text / code files — stream-read only what we need instead of loading entire file
            let maxChars = 30_000
            if let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               fileSize > maxChars * 4 {
                // Large file: read only first 30KB to avoid OOM on huge files
                guard let handle = FileHandle(forReadingAtPath: url.path) else {
                    print("[AttachedFile] Failed to open: \(name)")
                    return nil
                }
                defer { handle.closeFile() }
                let data = handle.readData(ofLength: maxChars * 4) // ~120KB max for UTF-8
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                    print("[AttachedFile] Failed to decode: \(name)")
                    return nil
                }
                content = String(text.prefix(maxChars)) + "\n\n[... truncated at \(maxChars) characters]"
            } else {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    print("[AttachedFile] Failed to read: \(name)")
                    return nil
                }
                content = text
            }
        }

        guard !content.isEmpty else {
            print("[AttachedFile] Empty content: \(name)")
            return nil
        }

        // Truncate very large files (for PDF/RTF/DOCX paths)
        let maxChars = 30_000
        let truncated = content.count > maxChars
            ? String(content.prefix(maxChars)) + "\n\n[... truncated at \(maxChars) characters]"
            : content

        return AttachedFile(url: url, name: name, ext: ext, content: truncated)
    }

    // MARK: - Extractors

    private static func extractPDF(url: URL) -> String {
        guard let result = try? ShellRunner.run(
            "/usr/bin/mdimport -d2 \"\(url.path)\" 2>&1 | head -500",
            timeout: 10
        ) else {
            // Fallback: use Python
            if let py = try? ShellRunner.run(
                "python3 -c \"import sys; from PyPDF2 import PdfReader; r=PdfReader(sys.argv[1]); [print(p.extract_text()) for p in r.pages[:20]]\" \"\(url.path)\" 2>/dev/null",
                timeout: 15
            ), !py.output.isEmpty {
                return py.output
            }
            return ""
        }

        // Try a simpler approach: textutil
        if let textutil = try? ShellRunner.run(
            "textutil -convert txt -stdout \"\(url.path)\" 2>/dev/null",
            timeout: 10
        ), !textutil.output.isEmpty {
            return textutil.output
        }

        // Last resort: strings
        if let strings = try? ShellRunner.run(
            "strings \"\(url.path)\" | head -500",
            timeout: 5
        ) {
            return strings.output
        }

        return result.output
    }

    private static func extractRTF(url: URL) -> String {
        if let textutil = try? ShellRunner.run(
            "textutil -convert txt -stdout \"\(url.path)\" 2>/dev/null",
            timeout: 10
        ) {
            return textutil.output
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func extractDocx(url: URL) -> String {
        if let textutil = try? ShellRunner.run(
            "textutil -convert txt -stdout \"\(url.path)\" 2>/dev/null",
            timeout: 10
        ) {
            return textutil.output
        }
        return ""
    }

    /// Format for injection into the user message
    var formattedForPrompt: String {
        return "--- Attached file: \(name) ---\n\(content)\n--- End of \(name) ---"
    }
}
