import Foundation

/// General pipeline that routes content specs to the right generation tools.
/// Thin routing layer — maps output types to existing tools.
enum ContentFactory {

    /// Route a content spec to the appropriate creation tool and execute it.
    static func create(spec: ContentSpec) async -> ContentResult {
        switch spec.outputType {
        case .presentation:
            return await createPresentation(spec)
        case .document:
            return await createDocument(spec)
        case .spreadsheet:
            return await createSpreadsheet(spec)
        case .summary:
            return await createSummary(spec)
        case .research:
            return await createResearch(spec)
        case .script:
            return await createScript(spec)
        }
    }

    // MARK: - Routers

    private static func createPresentation(_ spec: ContentSpec) async -> ContentResult {
        // Gather source content if provided
        let sourceContent = await gatherSources(spec.sourceMaterials)

        let prompt = """
        Create a presentation about: \(spec.topic)
        \(spec.audience.map { "Audience: \($0)" } ?? "")
        \(spec.format.map { "Format: \($0)" } ?? "")
        \(sourceContent.isEmpty ? "" : "Source material:\n\(String(sourceContent.prefix(3000)))")

        Output a JSON spec for the create_presentation tool.
        """

        do {
            let llmResponse = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 4096
            ).text ?? ""

            let result = try await ToolRegistry.shared.execute(
                toolName: "create_presentation",
                arguments: llmResponse
            )
            return ContentResult(success: true, message: result, outputPath: spec.outputPath)
        } catch {
            return ContentResult(success: false, message: "Failed: \(error)", outputPath: nil)
        }
    }

    private static func createDocument(_ spec: ContentSpec) async -> ContentResult {
        let sourceContent = await gatherSources(spec.sourceMaterials)

        let prompt = """
        Create a document about: \(spec.topic)
        \(spec.audience.map { "Audience: \($0)" } ?? "")
        \(spec.format.map { "Format: \($0)" } ?? "")
        \(sourceContent.isEmpty ? "" : "Source material:\n\(String(sourceContent.prefix(3000)))")

        Output a JSON spec for the create_word_document tool.
        """

        do {
            let llmResponse = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 4096
            ).text ?? ""

            let result = try await ToolRegistry.shared.execute(
                toolName: "create_word_document",
                arguments: llmResponse
            )
            return ContentResult(success: true, message: result, outputPath: spec.outputPath)
        } catch {
            return ContentResult(success: false, message: "Failed: \(error)", outputPath: nil)
        }
    }

    private static func createSpreadsheet(_ spec: ContentSpec) async -> ContentResult {
        let sourceContent = await gatherSources(spec.sourceMaterials)

        let prompt = """
        Create a spreadsheet about: \(spec.topic)
        \(spec.format.map { "Format: \($0)" } ?? "")
        \(sourceContent.isEmpty ? "" : "Source material:\n\(String(sourceContent.prefix(3000)))")

        Output a JSON spec for the create_spreadsheet tool.
        """

        do {
            let llmResponse = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 4096
            ).text ?? ""

            let result = try await ToolRegistry.shared.execute(
                toolName: "create_spreadsheet",
                arguments: llmResponse
            )
            return ContentResult(success: true, message: result, outputPath: spec.outputPath)
        } catch {
            return ContentResult(success: false, message: "Failed: \(error)", outputPath: nil)
        }
    }

    private static func createSummary(_ spec: ContentSpec) async -> ContentResult {
        let sourceContent = await gatherSources(spec.sourceMaterials)
        guard !sourceContent.isEmpty else {
            return ContentResult(success: false, message: "No source materials to summarize", outputPath: nil)
        }

        let prompt = """
        Summarize the following content about: \(spec.topic)
        \(spec.audience.map { "For audience: \($0)" } ?? "")

        Content:
        \(String(sourceContent.prefix(5000)))
        """

        do {
            let summary = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 2048
            ).text ?? ""

            if let outputPath = spec.outputPath {
                try summary.write(toFile: outputPath, atomically: true, encoding: .utf8)
            }
            return ContentResult(success: true, message: summary, outputPath: spec.outputPath)
        } catch {
            return ContentResult(success: false, message: "Failed: \(error)", outputPath: nil)
        }
    }

    private static func createResearch(_ spec: ContentSpec) async -> ContentResult {
        do {
            let searchResult = try await ToolRegistry.shared.execute(
                toolName: "search_web",
                arguments: "{\"query\": \"\(spec.topic)\"}"
            )

            let prompt = """
            Research report on: \(spec.topic)
            \(spec.audience.map { "For: \($0)" } ?? "")

            Web search results:
            \(searchResult)

            Write a concise research report synthesizing these findings.
            """

            let report = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 4096
            ).text ?? ""

            if let outputPath = spec.outputPath {
                try report.write(toFile: outputPath, atomically: true, encoding: .utf8)
            }
            return ContentResult(success: true, message: report, outputPath: spec.outputPath)
        } catch {
            return ContentResult(success: false, message: "Failed: \(error)", outputPath: nil)
        }
    }

    private static func createScript(_ spec: ContentSpec) async -> ContentResult {
        let sourceContent = await gatherSources(spec.sourceMaterials)

        let prompt = """
        Write a script/outline about: \(spec.topic)
        \(spec.audience.map { "For: \($0)" } ?? "")
        \(spec.format.map { "Format: \($0)" } ?? "")
        \(sourceContent.isEmpty ? "" : "Based on:\n\(String(sourceContent.prefix(3000)))")
        """

        do {
            let script = try await LLMServiceManager.shared.currentService.sendChatRequest(
                messages: [ChatMessage(role: "user", content: prompt)],
                tools: nil,
                maxTokens: 4096
            ).text ?? ""

            if let outputPath = spec.outputPath {
                try script.write(toFile: outputPath, atomically: true, encoding: .utf8)
            }
            return ContentResult(success: true, message: script, outputPath: spec.outputPath)
        } catch {
            return ContentResult(success: false, message: "Failed: \(error)", outputPath: nil)
        }
    }

    // MARK: - Helpers

    private static func gatherSources(_ paths: [String]?) async -> String {
        guard let paths = paths, !paths.isEmpty else { return "" }

        var combined = ""
        for path in paths.prefix(5) {
            do {
                let content: String
                if path.hasPrefix("http") {
                    content = try await ToolRegistry.shared.execute(
                        toolName: "read_web_page",
                        arguments: "{\"url\": \"\(path)\"}"
                    )
                } else {
                    content = try await ToolRegistry.shared.execute(
                        toolName: "read_file",
                        arguments: "{\"path\": \"\(path)\"}"
                    )
                }
                combined += "\n---\n\(String(content.prefix(2000)))"
            } catch {
                continue
            }
        }
        return combined
    }
}

struct ContentResult: Sendable {
    let success: Bool
    let message: String
    let outputPath: String?
}

// MARK: - Tool

struct CreateContentTool: ToolDefinition {
    let name = "create_content"
    let description = "Universal content creation — routes to the right tool (presentation, document, spreadsheet, summary, research report, or script) based on the output type."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "type": JSONSchema.enumString(description: "Content type", values: ["presentation", "document", "spreadsheet", "summary", "research", "script"]),
            "topic": JSONSchema.string(description: "Topic or subject matter"),
            "format": JSONSchema.string(description: "Optional format guidance (e.g., 'formal report', 'bullet points')"),
            "audience": JSONSchema.string(description: "Target audience (e.g., 'teacher', 'classmates', 'professional')"),
            "source_paths": JSONSchema.array(items: JSONSchema.string(description: "path"), description: "File paths or URLs to draw content from"),
            "output_path": JSONSchema.string(description: "Where to save the output file"),
        ], required: ["type", "topic"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let typeStr = try requiredString("type", from: args)
        let topic = try requiredString("topic", from: args)

        guard let outputType = ContentSpec.OutputType(rawValue: typeStr) else {
            return "Invalid type. Use: presentation, document, spreadsheet, summary, research, script"
        }

        let spec = ContentSpec(
            outputType: outputType,
            topic: topic,
            format: args["format"] as? String,
            audience: args["audience"] as? String,
            sourceMaterials: args["source_paths"] as? [String],
            outputPath: args["output_path"] as? String
        )

        let result = await ContentFactory.create(spec: spec)
        return result.success ? result.message : "Failed: \(result.message)"
    }
}
