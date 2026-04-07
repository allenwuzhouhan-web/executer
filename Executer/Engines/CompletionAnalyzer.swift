import Foundation

/// Analyzes incomplete documents to determine what's missing and how to complete them.
enum CompletionAnalyzer {

    struct Analysis: Sendable {
        let fileType: FileType
        let completionEstimate: Double  // 0.0–1.0
        let missingParts: [String]
        let suggestedAction: String
    }

    enum FileType: String, Sendable {
        case presentation, wordDocument, spreadsheet, text, markdown, unknown
    }

    /// Analyze a file and determine how complete it is.
    static func analyze(filePath: String) async -> Analysis {
        let ext = (filePath as NSString).pathExtension.lowercased()
        let fileType = classifyFileType(ext)

        switch fileType {
        case .presentation:
            return await analyzePresentationFile(filePath)
        case .wordDocument:
            return await analyzeDocumentFile(filePath)
        case .spreadsheet:
            return await analyzeSpreadsheetFile(filePath)
        case .text, .markdown:
            return await analyzeTextFile(filePath)
        case .unknown:
            return Analysis(fileType: .unknown, completionEstimate: 1.0,
                          missingParts: [], suggestedAction: "Unknown file type")
        }
    }

    private static func classifyFileType(_ ext: String) -> FileType {
        switch ext {
        case "pptx", "ppt": return .presentation
        case "docx", "doc": return .wordDocument
        case "xlsx", "xls", "csv": return .spreadsheet
        case "txt": return .text
        case "md": return .markdown
        default: return .unknown
        }
    }

    private static func analyzePresentationFile(_ path: String) async -> Analysis {
        // Use existing read_document tool to get content
        do {
            let content = try await ToolRegistry.shared.execute(
                toolName: "read_document",
                arguments: "{\"file_path\": \"\(path)\"}"
            )

            let slideCount = content.components(separatedBy: "Slide ").count - 1
            var missing: [String] = []

            if slideCount < 5 { missing.append("Only \(slideCount) slides — typical presentations have 8-15") }
            if !content.lowercased().contains("conclusion") && !content.lowercased().contains("summary") {
                missing.append("Missing conclusion/summary slide")
            }
            if !content.lowercased().contains("agenda") && !content.lowercased().contains("outline") {
                missing.append("Missing agenda/outline slide")
            }

            let estimate = min(1.0, Double(slideCount) / 10.0)
            return Analysis(
                fileType: .presentation,
                completionEstimate: estimate,
                missingParts: missing,
                suggestedAction: missing.isEmpty ? "Presentation appears complete" : "Add \(missing.count) missing sections"
            )
        } catch {
            return Analysis(fileType: .presentation, completionEstimate: 0.5,
                          missingParts: ["Could not read file"], suggestedAction: "Retry reading")
        }
    }

    private static func analyzeDocumentFile(_ path: String) async -> Analysis {
        do {
            let content = try await ToolRegistry.shared.execute(
                toolName: "read_document",
                arguments: "{\"file_path\": \"\(path)\"}"
            )

            var missing: [String] = []
            let wordCount = content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count

            if wordCount < 100 { missing.append("Very short document (\(wordCount) words)") }
            if content.contains("TODO") || content.contains("[TBD]") || content.contains("...") {
                missing.append("Contains placeholder text (TODO/TBD)")
            }

            let estimate = min(1.0, Double(wordCount) / 500.0)
            return Analysis(
                fileType: .wordDocument,
                completionEstimate: estimate,
                missingParts: missing,
                suggestedAction: missing.isEmpty ? "Document appears complete" : "Complete \(missing.count) sections"
            )
        } catch {
            return Analysis(fileType: .wordDocument, completionEstimate: 0.5,
                          missingParts: ["Could not read file"], suggestedAction: "Retry reading")
        }
    }

    private static func analyzeSpreadsheetFile(_ path: String) async -> Analysis {
        do {
            let content = try await ToolRegistry.shared.execute(
                toolName: "read_document",
                arguments: "{\"file_path\": \"\(path)\"}"
            )

            var missing: [String] = []
            let rows = content.components(separatedBy: "\n").filter { !$0.isEmpty }

            if rows.count < 3 { missing.append("Very few data rows (\(rows.count))") }

            let estimate = min(1.0, Double(rows.count) / 20.0)
            return Analysis(
                fileType: .spreadsheet,
                completionEstimate: estimate,
                missingParts: missing,
                suggestedAction: missing.isEmpty ? "Spreadsheet appears complete" : "Add more data"
            )
        } catch {
            return Analysis(fileType: .spreadsheet, completionEstimate: 0.5,
                          missingParts: ["Could not read file"], suggestedAction: "Retry reading")
        }
    }

    private static func analyzeTextFile(_ path: String) async -> Analysis {
        do {
            let content = try await ToolRegistry.shared.execute(
                toolName: "read_file",
                arguments: "{\"path\": \"\(path)\"}"
            )

            var missing: [String] = []
            let wordCount = content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count

            if content.contains("TODO") || content.contains("[TBD]") {
                missing.append("Contains placeholder text")
            }
            if wordCount < 50 { missing.append("Very short (\(wordCount) words)") }

            let estimate = min(1.0, Double(wordCount) / 300.0)
            return Analysis(
                fileType: .text,
                completionEstimate: estimate,
                missingParts: missing,
                suggestedAction: missing.isEmpty ? "Text appears complete" : "Expand content"
            )
        } catch {
            return Analysis(fileType: .text, completionEstimate: 0.5,
                          missingParts: ["Could not read file"], suggestedAction: "Retry reading")
        }
    }
}
