import Foundation

// MARK: - RAG Ingest Tool

/// Tool: rag_ingest — Ingest files/directories into the local RAG vector store for semantic search.
struct RAGIngestTool: ToolDefinition {
    let name = "rag_ingest"
    let description = """
        Ingest one or more files into the local RAG vector store for later semantic search. \
        Supports: txt, md, pdf, docx, csv, code files (py, swift, js, ts, go, etc.). \
        Files are chunked and embedded locally using ChromaDB. \
        Use a collection name to organize documents by topic or project. \
        Already-ingested files (same content) are automatically skipped.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to a file or directory to ingest. Directories are walked recursively."),
            "collection": JSONSchema.string(description: "Collection name to store documents in. Default: \"default\". Use descriptive names like \"work_notes\" or \"project_docs\"."),
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let collection = optionalString("collection", from: args) ?? "default"

        let expandedPath = NSString(string: path).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return "Error: Path not found: \(expandedPath)"
        }

        return try await RAGExecutor.runRAGEngine(
            command: "ingest",
            args: ["--path", expandedPath, "--collection", collection]
        )
    }
}

// MARK: - RAG Search Tool

/// Tool: rag_search — Semantic search across ingested documents.
struct RAGSearchTool: ToolDefinition {
    let name = "rag_search"
    let description = """
        Search your ingested documents using semantic similarity. \
        Returns the most relevant text chunks with source file information. \
        Use this to find information across all documents you've previously ingested with rag_ingest.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Natural language search query. Be descriptive for better results."),
            "collection": JSONSchema.string(description: "Collection to search in. Default: \"default\"."),
            "limit": JSONSchema.integer(description: "Maximum number of results to return (1-20). Default: 5.", minimum: 1, maximum: 20),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let collection = optionalString("collection", from: args) ?? "default"
        let limit = optionalInt("limit", from: args) ?? 5

        return try await RAGExecutor.runRAGEngine(
            command: "search",
            args: ["--query", query, "--collection", collection, "--limit", String(limit)]
        )
    }
}

// MARK: - RAG List Collections Tool

/// Tool: rag_list_collections — List all RAG collections with stats.
struct RAGListCollectionsTool: ToolDefinition {
    let name = "rag_list_collections"
    let description = "List all document collections in the RAG vector store, showing chunk counts and file counts."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        return try await RAGExecutor.runRAGEngine(command: "list", args: [])
    }
}

// MARK: - RAG Delete Collection Tool

/// Tool: rag_delete_collection — Delete a RAG collection.
struct RAGDeleteCollectionTool: ToolDefinition {
    let name = "rag_delete_collection"
    let description = "Delete a document collection from the RAG vector store. This permanently removes all ingested documents and embeddings in that collection."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "collection": JSONSchema.string(description: "Name of the collection to delete."),
        ], required: ["collection"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let collection = try requiredString("collection", from: args)

        return try await RAGExecutor.runRAGEngine(
            command: "delete",
            args: ["--collection", collection]
        )
    }
}

// MARK: - RAG Collection Info Tool

/// Tool: rag_collection_info — Get detailed info about a RAG collection.
struct RAGCollectionInfoTool: ToolDefinition {
    let name = "rag_collection_info"
    let description = "Get detailed information about a RAG collection, including the list of ingested files and chunk counts per file."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "collection": JSONSchema.string(description: "Collection name to inspect. Default: \"default\"."),
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let collection = optionalString("collection", from: args) ?? "default"

        return try await RAGExecutor.runRAGEngine(
            command: "info",
            args: ["--collection", collection]
        )
    }
}

// MARK: - RAG Executor (Python bridge)

/// Shared executor for running the RAG Python engine.
enum RAGExecutor {

    /// Run the rag_engine.py script with the given command and arguments.
    static func runRAGEngine(command: String, args: [String]) async throws -> String {
        let appSupport = URL.applicationSupportDirectory
        let execDir = appSupport.appendingPathComponent("Executer")

        // Deploy Python script from bundle
        PPTExecutor.ensureResource("rag_engine", ext: "py", in: execDir)

        let enginePath = execDir.appendingPathComponent("rag_engine.py")
        guard FileManager.default.fileExists(atPath: enginePath.path) else {
            return "Error: rag_engine.py not found in app resources"
        }

        let python = PPTExecutor.findPython()
        let fullArgs = [command] + args

        let result = try await PPTExecutor.runPython(
            python: python,
            script: enginePath.path,
            args: fullArgs
        )

        // Parse and format the JSON result
        if let resultData = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            return formatRAGResult(json, command: command)
        }

        // Fallback: return raw output
        if !result.stdout.isEmpty {
            return result.stdout
        }
        return "RAG engine error: \(result.stderr.prefix(500))"
    }

    /// Format RAG engine JSON result into a human-readable string for the LLM.
    private static func formatRAGResult(_ json: [String: Any], command: String) -> String {
        let success = json["success"] as? Bool ?? false

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            return "RAG error: \(error)"
        }

        switch command {
        case "ingest":
            let ingested = json["files_ingested"] as? Int ?? 0
            let skipped = json["files_skipped"] as? Int ?? 0
            let chunks = json["total_chunks"] as? Int ?? 0
            let total = json["collection_total"] as? Int ?? 0
            let collection = json["collection"] as? String ?? "default"
            var msg = "Ingested \(ingested) files (\(chunks) chunks) into collection '\(collection)'. Total chunks in collection: \(total)."
            if skipped > 0 {
                msg += " Skipped \(skipped) files (already ingested or unsupported)."
            }
            if let errors = json["errors"] as? [String], !errors.isEmpty {
                msg += "\nErrors: " + errors.joined(separator: "; ")
            }
            return msg

        case "search":
            guard let results = json["results"] as? [[String: Any]], !results.isEmpty else {
                let query = json["query"] as? String ?? ""
                return "No results found for query: \"\(query)\""
            }
            var parts: [String] = []
            for (i, r) in results.enumerated() {
                let content = r["content"] as? String ?? ""
                let filename = r["filename"] as? String ?? "unknown"
                let source = r["source"] as? String ?? ""
                let relevance = r["relevance"] as? Double ?? 0
                parts.append("[\(i + 1)] (relevance: \(String(format: "%.2f", relevance))) \(filename)\n   Source: \(source)\n   \(content)")
            }
            let query = json["query"] as? String ?? ""
            return "Search results for \"\(query)\":\n\n" + parts.joined(separator: "\n\n")

        case "list":
            guard let collections = json["collections"] as? [[String: Any]], !collections.isEmpty else {
                return "No RAG collections found. Use rag_ingest to add documents."
            }
            var lines = ["RAG Collections:"]
            for col in collections {
                let name = col["name"] as? String ?? "?"
                let chunks = col["chunks"] as? Int ?? 0
                let files = col["files"] as? Int ?? 0
                lines.append("  • \(name): \(files) files, \(chunks) chunks")
            }
            return lines.joined(separator: "\n")

        case "delete":
            let deleted = json["deleted"] as? String ?? ""
            return "Deleted collection '\(deleted)'"

        case "info":
            let collection = json["collection"] as? String ?? ""
            let totalChunks = json["total_chunks"] as? Int ?? 0
            let totalFiles = json["total_files"] as? Int ?? 0
            var msg = "Collection '\(collection)': \(totalFiles) files, \(totalChunks) chunks"
            if let files = json["files"] as? [[String: Any]], !files.isEmpty {
                msg += "\n\nFiles:"
                for f in files.prefix(50) {
                    let path = f["path"] as? String ?? "?"
                    let chunks = f["chunks"] as? Int ?? 0
                    msg += "\n  • \(path) (\(chunks) chunks)"
                }
                if files.count > 50 {
                    msg += "\n  ... and \(files.count - 50) more"
                }
            }
            return msg

        default:
            // Return raw JSON for unknown commands
            if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "OK"
        }
    }
}
