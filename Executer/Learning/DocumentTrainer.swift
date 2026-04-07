import Foundation

/// Coordinator that accepts document files, extracts their content,
/// runs the 3-agent analysis pipeline, and stores learned profiles.
///
/// Supports: PPTX, DOCX, KEY, PDF, Pages, Numbers, XLSX
/// Uses bundled ppt_design_extractor.py for PPTX (full design language extraction).
/// Apple Silicon optimized: extraction on utility QoS, LLM on userInitiated.
final class DocumentTrainer {
    static let shared = DocumentTrainer()

    private let pipeline = TrainerAgentPipeline()
    private let store = DocumentStudyStore.shared

    /// Path to bundled/installed Python scripts in App Support.
    private let scriptsDir: URL = {
        let appSupport = URL.applicationSupportDirectory
        return appSupport.appendingPathComponent("Executer", isDirectory: true)
    }()

    private init() {
        installScriptsIfNeeded()
    }

    // MARK: - Python Detection

    /// Find python3 binary. Delegates to PPTExecutor which manages the shared venv.
    private func findPython() -> String {
        PPTExecutor.findPython()
    }

    /// Quick synchronous shell for python detection.
    private func shellSync(_ command: String, args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Script Installation

    /// Copy bundled Python scripts to App Support if not already present.
    private func installScriptsIfNeeded() {
        let fm = FileManager.default
        let scripts = ["ppt_design_extractor.py", "ppt_engine.py", "docx_engine.py", "xlsx_engine.py"]

        for scriptName in scripts {
            let dest = scriptsDir.appendingPathComponent(scriptName)

            // Always overwrite with latest bundled version
            if let bundled = Bundle.main.url(forResource: scriptName.replacingOccurrences(of: ".py", with: ""),
                                              withExtension: "py") {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: bundled, to: dest)
                // Make executable
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
        }
    }

    // MARK: - Train From File

    func train(
        fileURL: URL,
        onProgress: @MainActor @escaping (String) -> Void
    ) async throws -> DocumentStudyProfile {
        let filename = fileURL.lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0

        await onProgress("Extracting content from \(filename)...")

        let content = try await extractContent(from: fileURL, format: ext)
        guard !content.isEmpty else {
            throw TrainerAgentPipeline.TrainerError.extractionFailed("No text content extracted from \(filename)")
        }

        await onProgress("Analyzing style metadata...")
        let styleJSON = await extractStyle(from: fileURL, format: ext)

        let profile = try await pipeline.analyze(
            content: content,
            styleJSON: styleJSON,
            filename: filename,
            format: ext,
            fileSize: fileSize,
            onProgress: onProgress
        )

        store.save(profile)

        // Auto-extract design language from PPTX for future creation
        if ext == "pptx" || ext == "ppt" {
            await onProgress("Extracting design language for future presentations...")
            await autoExtractDesignLanguage(from: fileURL)
        }

        await onProgress("Training complete — learned from \(filename)")
        return profile
    }

    func trainBatch(
        fileURLs: [URL],
        onProgress: @MainActor @escaping (String) -> Void
    ) async -> [Result<DocumentStudyProfile, Error>] {
        var results: [Result<DocumentStudyProfile, Error>] = []
        for (i, url) in fileURLs.enumerated() {
            await onProgress("Training \(i + 1)/\(fileURLs.count): \(url.lastPathComponent)")
            do {
                let profile = try await train(fileURL: url, onProgress: onProgress)
                results.append(.success(profile))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }

    // MARK: - Auto Design Language Extraction

    /// After training on a PPTX, auto-extract design_language.json for the PPT engine.
    /// Saves both a global default AND a per-file design for multi-style support.
    private func autoExtractDesignLanguage(from fileURL: URL) async {
        let extractorPath = scriptsDir.appendingPathComponent("ppt_design_extractor.py")
        guard FileManager.default.fileExists(atPath: extractorPath.path) else { return }

        let filename = fileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_")

        // Save per-file design language (include .json extension in the path)
        let perFileOutput = scriptsDir.appendingPathComponent("design_language_\(filename).json")
        let _ = try? await runPythonScript(
            extractorPath.path,
            args: [fileURL.path, "-o", perFileOutput.path, "--format", "json"]
        )

        // Also save as the global default (latest trained file wins)
        let globalOutput = scriptsDir.appendingPathComponent("design_language.json")
        let _ = try? await runPythonScript(
            extractorPath.path,
            args: [fileURL.path, "-o", globalOutput.path, "--format", "json"]
        )

        if FileManager.default.fileExists(atPath: perFileOutput.path) {
            print("[DocumentTrainer] Design language saved: \(perFileOutput.lastPathComponent)")
        }
    }

    // MARK: - Content Extraction

    private func extractContent(from url: URL, format: String) async throws -> String {
        switch format {
        case "pptx", "ppt":
            return try await extractPPTX(url)
        case "docx", "doc":
            return try await extractDOCX(url)
        case "key":
            return try await extractKeynote(url)
        case "pages":
            return try await extractPages(url)
        case "pdf":
            return try await extractPDF(url)
        case "xlsx", "xls":
            return try await extractXLSX(url)
        case "numbers":
            return try await extractNumbers(url)
        default:
            return try await extractText(url)
        }
    }

    // MARK: - PPTX: Use bundled ppt_design_extractor.py

    private func extractPPTX(_ url: URL) async throws -> String {
        let extractorPath = scriptsDir.appendingPathComponent("ppt_design_extractor.py")

        // Method 1: Full design extractor (best quality)
        if FileManager.default.fileExists(atPath: extractorPath.path) {
            let result = try await runPythonScript(
                extractorPath.path,
                args: [url.path, "--format", "json"]
            )
            if !result.stdout.isEmpty && result.exitCode == 0 {
                print("[DocumentTrainer] PPTX extracted via design extractor (\(result.stdout.count) chars)")
                return result.stdout
            }
            if !result.stderr.isEmpty {
                print("[DocumentTrainer] ppt_design_extractor failed: \(result.stderr.prefix(500))")
            }
        }

        // Method 2: Inline python-pptx
        let script = """
            import json, sys
            from pptx import Presentation
            prs = Presentation(sys.argv[1])
            slides = []
            for i, slide in enumerate(prs.slides):
                shapes_text = []
                for shape in slide.shapes:
                    if shape.has_text_frame:
                        for para in shape.text_frame.paragraphs:
                            text = para.text.strip()
                            if text:
                                level = para.level if para.level else 0
                                bold = any(run.font.bold for run in para.runs if run.font.bold is not None)
                                shapes_text.append({"text": text, "level": level, "bold": bold})
                layout_name = slide.slide_layout.name if slide.slide_layout else "unknown"
                slides.append({"slide": i+1, "layout": layout_name, "content": shapes_text})
            print(json.dumps({"total_slides": len(slides), "slides": slides}, ensure_ascii=False, indent=2))
            """
        let pythonResult = try await runInlinePython(script: script, args: [url.path])
        if pythonResult.count > 20 {
            print("[DocumentTrainer] PPTX extracted via inline python-pptx (\(pythonResult.count) chars)")
            return pythonResult
        }

        // Method 3: PPTX is a ZIP with XML — extract text directly without python-pptx
        print("[DocumentTrainer] Python extraction failed, using ZIP/XML fallback")
        let zipResult = try await extractPPTXviaZIP(url)
        if zipResult.count > 20 {
            print("[DocumentTrainer] PPTX extracted via ZIP/XML (\(zipResult.count) chars)")
            return zipResult
        }

        // Method 4: Spotlight metadata (last resort)
        let md = try await shell(path: "/usr/bin/mdimport", args: ["-d2", url.path])
        if md.count > 50 { return md }

        throw TrainerAgentPipeline.TrainerError.extractionFailed(
            "Could not extract text from PPTX. Ensure python-pptx is installed: " +
            "~/Library/Application Support/Executer/python_env/bin/pip3 install python-pptx"
        )
    }

    /// Extract PPTX text by treating it as a ZIP and parsing the XML directly.
    /// No Python dependencies needed — pure Swift.
    private func extractPPTXviaZIP(_ url: URL) async throws -> String {
        // PPTX is a ZIP file. Slides are at ppt/slides/slide1.xml, slide2.xml, etc.
        // We unzip, find all slide XMLs, and strip XML tags to get raw text.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Unzip
        let unzipResult = try await shell(path: "/usr/bin/unzip", args: ["-o", "-q", url.path, "-d", tempDir.path])
        _ = unzipResult  // unzip output not needed

        // Find slide XML files
        let slidesDir = tempDir.appendingPathComponent("ppt/slides")
        guard let slideFiles = try? FileManager.default.contentsOfDirectory(
            at: slidesDir, includingPropertiesForKeys: nil
        ).filter({ $0.lastPathComponent.hasPrefix("slide") && $0.pathExtension == "xml" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else {
            return ""
        }

        var allText = ""
        for (i, slideFile) in slideFiles.enumerated() {
            guard let xmlData = try? Data(contentsOf: slideFile),
                  let xmlString = String(data: xmlData, encoding: .utf8) else { continue }

            allText += "--- Slide \(i + 1) ---\n"

            // Extract text from <a:t> tags (PowerPoint text runs)
            let pattern = try NSRegularExpression(pattern: "<a:t>([^<]+)</a:t>")
            let range = NSRange(xmlString.startIndex..., in: xmlString)
            let matches = pattern.matches(in: xmlString, range: range)

            for match in matches {
                if let textRange = Range(match.range(at: 1), in: xmlString) {
                    let text = String(xmlString[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        allText += text + "\n"
                    }
                }
            }
            allText += "\n"
        }

        return allText
    }

    // MARK: - DOCX

    private func extractDOCX(_ url: URL) async throws -> String {
        // textutil is reliable for DOCX on macOS
        let textutil = try await shell(path: "/usr/bin/textutil", args: ["-convert", "txt", "-stdout", url.path])
        if textutil.count > 50 { return textutil }

        // Fallback: python-docx
        let script = """
            import json, sys
            try:
                from docx import Document
                doc = Document(sys.argv[1])
                sections = []
                for para in doc.paragraphs:
                    if para.text.strip():
                        sections.append({"style": para.style.name, "text": para.text.strip()})
                print(json.dumps({"paragraphs": len(sections), "content": sections}, ensure_ascii=False, indent=2))
            except ImportError:
                print("ERROR: python-docx not installed. Run: pip3 install python-docx", file=sys.stderr)
                sys.exit(1)
            """
        return try await runInlinePython(script: script, args: [url.path])
    }

    // MARK: - Keynote

    private func extractKeynote(_ url: URL) async throws -> String {
        // Try AppleScript first — direct slide text extraction
        let appleScript = """
            set filePath to POSIX file "\(url.path)"
            tell application "System Events"
                set keynoteRunning to (name of processes) contains "Keynote"
            end tell
            tell application "Keynote"
                open filePath
                delay 2
                set theDoc to front document
                set slideTexts to ""
                repeat with i from 1 to count of slides of theDoc
                    set s to slide i of theDoc
                    set slideTexts to slideTexts & "--- Slide " & i & " ---" & linefeed
                    try
                        repeat with ti from 1 to count of text items of s
                            set t to text item ti of s
                            set slideTexts to slideTexts & object text of t & linefeed
                        end repeat
                    end try
                end repeat
                if not keynoteRunning then quit
                return slideTexts
            end tell
            """
        let result = try await shell(path: "/usr/bin/osascript", args: ["-e", appleScript])
        if result.count > 50 { return result }

        // Fallback: Spotlight metadata
        return try await shell(path: "/usr/bin/mdimport", args: ["-d2", url.path])
    }

    // MARK: - Other Formats

    private func extractPages(_ url: URL) async throws -> String {
        let result = try await shell(path: "/usr/bin/textutil", args: ["-convert", "txt", "-stdout", url.path])
        if result.count > 50 { return result }
        return try await shell(path: "/usr/bin/mdimport", args: ["-d2", url.path])
    }

    private func extractPDF(_ url: URL) async throws -> String {
        // Try Python PyPDF2 first (better text extraction)
        let script = """
            import sys
            try:
                from PyPDF2 import PdfReader
                reader = PdfReader(sys.argv[1])
                text = ""
                for i, page in enumerate(reader.pages[:50]):
                    text += f"--- Page {i+1} ---\\n"
                    text += (page.extract_text() or "") + "\\n"
                print(text)
            except ImportError:
                # Fallback: textutil
                import subprocess
                r = subprocess.run(["/usr/bin/textutil", "-convert", "txt", "-stdout", sys.argv[1]],
                                   capture_output=True, text=True)
                print(r.stdout)
            except Exception as e:
                print(f"ERROR: {e}", file=sys.stderr)
                sys.exit(1)
            """
        let result = try await runInlinePython(script: script, args: [url.path])
        if result.count > 50 { return result }

        return try await shell(path: "/usr/bin/mdimport", args: ["-d2", url.path])
    }

    private func extractXLSX(_ url: URL) async throws -> String {
        let script = """
            import json, sys
            try:
                from openpyxl import load_workbook
                wb = load_workbook(sys.argv[1], read_only=True, data_only=True)
                sheets = []
                for name in wb.sheetnames:
                    ws = wb[name]
                    rows = []
                    for row in ws.iter_rows(max_row=100, values_only=True):
                        rows.append([str(c) if c is not None else "" for c in row])
                    sheets.append({"name": name, "rows": len(rows), "data": rows[:50]})
                print(json.dumps({"sheets": sheets}, ensure_ascii=False, indent=2))
            except ImportError:
                print("ERROR: openpyxl not installed. Run: pip3 install openpyxl", file=sys.stderr)
                sys.exit(1)
            """
        return try await runInlinePython(script: script, args: [url.path])
    }

    private func extractNumbers(_ url: URL) async throws -> String {
        return try await shell(path: "/usr/bin/mdimport", args: ["-d2", url.path])
    }

    private func extractText(_ url: URL) async throws -> String {
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Style Extraction (uses full design extractor for PPTX)

    private func extractStyle(from url: URL, format: String) async -> String? {
        guard format == "pptx" || format == "ppt" else { return nil }

        let extractorPath = scriptsDir.appendingPathComponent("ppt_design_extractor.py")
        guard FileManager.default.fileExists(atPath: extractorPath.path) else { return nil }

        // Run the full design extractor — outputs JSON with complete style analysis
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("design_\(UUID().uuidString)")

        let result = try? await runPythonScript(
            extractorPath.path,
            args: [url.path, "-o", outputPath.path, "--format", "json"]
        )

        // Read the JSON output
        let jsonPath = URL(fileURLWithPath: outputPath.path + ".json")
        defer { try? FileManager.default.removeItem(at: jsonPath) }

        if let data = try? Data(contentsOf: jsonPath),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        // Fallback: use stdout if file wasn't written
        return result?.stdout.isEmpty == false ? result?.stdout : nil
    }

    // MARK: - Shell Helpers

    struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Run a bundled Python script with proper Python path detection.
    private func runPythonScript(_ scriptPath: String, args: [String]) async throws -> ProcessResult {
        let python = findPython()
        let allArgs = [scriptPath] + args

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = allArgs
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = ProcessInfo.processInfo.environment.merging([
                    "PYTHONIOENCODING": "utf-8",
                    "PYTHONUNBUFFERED": "1",
                    // Include Homebrew paths so python-pptx can be found
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
                ]) { _, new in new }

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""

                    let truncated = stdout.count > 30000 ? String(stdout.prefix(30000)) + "\n[truncated]" : stdout
                    continuation.resume(returning: ProcessResult(stdout: truncated, stderr: stderr, exitCode: process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run an inline Python script (written to temp file).
    private func runInlinePython(script: String, args: [String]) async throws -> String {
        let tempScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("trainer_\(UUID().uuidString).py")
        try script.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }

        let result = try await runPythonScript(tempScript.path, args: args)
        if result.exitCode != 0 && !result.stderr.isEmpty {
            print("[DocumentTrainer] Python error: \(result.stderr.prefix(500))")
        }
        return result.stdout
    }

    /// Run a system command directly (for textutil, mdimport, osascript).
    private func shell(path: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let truncated = output.count > 30000 ? String(output.prefix(30000)) + "\n[truncated]" : output
                    continuation.resume(returning: truncated)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
