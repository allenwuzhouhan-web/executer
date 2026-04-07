import Foundation

/// Takes any incomplete work artifact and finishes it. Orchestrates existing document creation tools.
actor WorkCompletionEngine {
    static let shared = WorkCompletionEngine()

    // MARK: - Complete Work

    /// Analyze and complete an incomplete document.
    func complete(filePath: String) async -> CompletionResult {
        let analysis = await CompletionAnalyzer.analyze(filePath: filePath)

        guard analysis.completionEstimate < 0.9 else {
            return CompletionResult(
                success: true,
                message: "File appears already complete (\(Int(analysis.completionEstimate * 100))%)",
                outputPath: filePath
            )
        }

        switch analysis.fileType {
        case .presentation:
            return await completePresentationFile(filePath, analysis: analysis)
        case .wordDocument:
            return await completeWordDocument(filePath, analysis: analysis)
        case .spreadsheet:
            return await completeSpreadsheet(filePath, analysis: analysis)
        case .text, .markdown:
            return await completeTextFile(filePath, analysis: analysis)
        case .unknown:
            return CompletionResult(success: false, message: "Unknown file type", outputPath: nil)
        }
    }

    // MARK: - Presentation Completion

    private func completePresentationFile(_ path: String, analysis: CompletionAnalyzer.Analysis) async -> CompletionResult {
        do {
            // Read existing content
            let content = try await ToolRegistry.shared.execute(
                toolName: "read_document",
                arguments: "{\"file_path\": \"\(path)\"}"
            )

            // Ask LLM what slides to add
            let prompt = """
            This presentation is \(Int(analysis.completionEstimate * 100))% complete.
            Missing: \(analysis.missingParts.joined(separator: "; "))

            Existing content:
            \(String(content.prefix(2000)))

            Generate a JSON spec for additional slides to complete this presentation.
            Use the same topic and style. Output ONLY valid JSON matching the create_presentation tool format.
            Include only the NEW slides to add.
            """

            let llmResponse = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 4096
            ).text ?? ""

            // Extract existing design language if available
            let filename = (path as NSString).lastPathComponent
            let safeName = (filename as NSString).deletingPathExtension.replacingOccurrences(of: " ", with: "_")

            // Create a completion file alongside the original
            let dir = (path as NSString).deletingLastPathComponent
            let completedPath = dir + "/" + safeName + "_completed.pptx"

            let result = try await ToolRegistry.shared.execute(
                toolName: "create_presentation",
                arguments: llmResponse
            )

            return CompletionResult(
                success: true,
                message: "Generated completion slides. \(result)",
                outputPath: completedPath
            )
        } catch {
            return CompletionResult(success: false, message: "Failed: \(error.localizedDescription)", outputPath: nil)
        }
    }

    // MARK: - Word Document Completion

    private func completeWordDocument(_ path: String, analysis: CompletionAnalyzer.Analysis) async -> CompletionResult {
        do {
            let content = try await ToolRegistry.shared.execute(
                toolName: "read_document",
                arguments: "{\"file_path\": \"\(path)\"}"
            )

            let prompt = """
            This document is \(Int(analysis.completionEstimate * 100))% complete.
            Missing: \(analysis.missingParts.joined(separator: "; "))

            Existing content:
            \(String(content.prefix(3000)))

            Write the continuation/completion of this document. Match the existing tone and style.
            Output the additional content as plain text that will be appended.
            """

            let continuation = try await { () async throws -> String in
                let resp = try await LLMServiceManager.shared.currentService.sendChatRequest(
                    messages: [ChatMessage(role: "user", content: prompt)],
                    tools: nil,
                    maxTokens: 4096
                )
                return resp.text ?? ""
            }()

            // Append to original file
            let result = try await ToolRegistry.shared.execute(
                toolName: "append_to_file",
                arguments: "{\"path\": \"\(path)\", \"content\": \"\(continuation.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))\"}"
            )

            return CompletionResult(
                success: true,
                message: "Appended completion content. \(result)",
                outputPath: path
            )
        } catch {
            return CompletionResult(success: false, message: "Failed: \(error.localizedDescription)", outputPath: nil)
        }
    }

    // MARK: - Spreadsheet Completion

    private func completeSpreadsheet(_ path: String, analysis: CompletionAnalyzer.Analysis) async -> CompletionResult {
        // Spreadsheets are harder to auto-complete — just report status
        return CompletionResult(
            success: false,
            message: "Spreadsheet at \(Int(analysis.completionEstimate * 100))% — needs manual data entry. Missing: \(analysis.missingParts.joined(separator: "; "))",
            outputPath: nil
        )
    }

    // MARK: - Text File Completion

    private func completeTextFile(_ path: String, analysis: CompletionAnalyzer.Analysis) async -> CompletionResult {
        do {
            let content = try await ToolRegistry.shared.execute(
                toolName: "read_file",
                arguments: "{\"path\": \"\(path)\"}"
            )

            let prompt = """
            Complete this text. It's \(Int(analysis.completionEstimate * 100))% done.
            Missing: \(analysis.missingParts.joined(separator: "; "))

            Existing:
            \(String(content.prefix(3000)))

            Write ONLY the continuation. Match tone and style.
            """

            let continuation = try await { () async throws -> String in
                let resp = try await LLMServiceManager.shared.currentService.sendChatRequest(
                    messages: [ChatMessage(role: "user", content: prompt)],
                    tools: nil,
                    maxTokens: 4096
                )
                return resp.text ?? ""
            }()

            let result = try await ToolRegistry.shared.execute(
                toolName: "append_to_file",
                arguments: "{\"path\": \"\(path)\", \"content\": \"\\n\\n\(continuation.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))\"}"
            )

            return CompletionResult(
                success: true,
                message: "Appended completion. \(result)",
                outputPath: path
            )
        } catch {
            return CompletionResult(success: false, message: "Failed: \(error.localizedDescription)", outputPath: nil)
        }
    }
}

struct CompletionResult: Sendable {
    let success: Bool
    let message: String
    let outputPath: String?
}

// MARK: - Tools

struct CompleteWorkTool: ToolDefinition {
    let name = "complete_work"
    let description = "Analyze an incomplete document and generate the missing content to finish it. Works with presentations, Word docs, and text files."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "file_path": JSONSchema.string(description: "Absolute path to the incomplete file"),
        ], required: ["file_path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("file_path", from: args)

        let result = await WorkCompletionEngine.shared.complete(filePath: path)
        return result.success
            ? "Completed: \(result.message)"
            : "Could not complete: \(result.message)"
    }
}

struct AnalyzeCompletionStatusTool: ToolDefinition {
    let name = "analyze_completion_status"
    let description = "Analyze how complete a document is and what parts are missing."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "file_path": JSONSchema.string(description: "Absolute path to the file to analyze"),
        ], required: ["file_path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("file_path", from: args)

        let analysis = await CompletionAnalyzer.analyze(filePath: path)

        var result = "File type: \(analysis.fileType.rawValue)\n"
        result += "Completion: \(Int(analysis.completionEstimate * 100))%\n"
        if !analysis.missingParts.isEmpty {
            result += "Missing:\n"
            for part in analysis.missingParts {
                result += "  - \(part)\n"
            }
        }
        result += "Suggested action: \(analysis.suggestedAction)"
        return result
    }
}
