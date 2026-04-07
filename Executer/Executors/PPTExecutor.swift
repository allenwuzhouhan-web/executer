import Foundation

/// Tool: create_presentation — Creates a .pptx using the bundled PPT engine + trained design knowledge.
struct CreatePresentationTool: ToolDefinition {
    let name = "create_presentation"
    let description = """
        Create a PowerPoint (.pptx) presentation. Automatically applies the user's trained design language \
        if available (colors, fonts, spacing, layout patterns extracted from their reference presentations).

        ## CRITICAL: EXECUTE IMMEDIATELY.
        Do NOT describe the slides in text. Do NOT outline your plan. Do NOT list what you "would" include.
        Generate the full JSON spec and call this tool RIGHT NOW in this response. No preamble, no explanation.

        ## MANDATORY WORKFLOW for 4+ slide decks:
        1. FIRST call search_images to find 2-4 relevant, high-quality image URLs for your topic.
        2. THEN create the spec, embedding ONLY those returned URLs in full_image, image_right, or content slides.

        ## CRITICAL IMAGE RULE:
        NEVER invent, guess, or fabricate image URLs or filenames. Only use URLs returned by search_images. \
        Filenames like "ai-trends-2025.jpg" or "team-photo.png" DO NOT EXIST and will be stripped. \
        If you haven't called search_images yet, either call it first or make a deck WITHOUT images — \
        a clean text-only deck is far better than one with broken image placeholders.

        ## DESIGN PRINCIPLES:

        1. RESTRAINT IS DESIGN. A clean slide with 3 words and perfect placement beats a busy slide with \
        every feature used. White space is not empty — it is breathing room.

        2. ONE IDEA PER SLIDE. If you have 8 bullets, split into 2-3 slides. Key number? big_number slide. Never cram.

        3. VISUAL HIERARCHY. Every slide has ONE thing the eye hits first — the most important thing.

        4. LAYOUT VARIETY IS MANDATORY. Do NOT make a deck of only content+bullets. Use at least 3 different \
        layout types. Map content to the RIGHT layout: metrics → big_number, features → cards, steps → process, \
        dates → timeline, impact statements → full_image with background photo.

        5. LAYOUT RHYTHM. title → content → big_number → image_right → section → cards → process → title. \
        Never 3+ identical layouts in a row. Section dividers every 3-5 slides.

        6. LESS TEXT, MORE STRUCTURE. Bullets → cards. Steps → process. Dates → timeline. Before/after → comparison.

        ## Available Layouts (15 types):
        - title: Opening/closing. Title + subtitle centered.
        - section: Section divider. Large title, accent color.
        - content: Title + body/bullets. Optional image dict: {"url": "...", "position": "right"}.
        - two_column: Side-by-side. left_title/left_bullets + right_title/right_bullets. Optional left_image/right_image.
        - quote: Centered quote with attribution.
        - image_left / image_right: Image on one side, text on the other. Use image_url for online images.
        - data_table: Styled table with headers and rows.
        - big_number: One large metric + label + body. Use for impact stats.
        - full_image: Full-bleed background image + text overlay. Use image or image_url key.
        - comparison: Side-by-side panels. For before/after, pros/cons.
        - cards: Grid of 1-8 cards with title/body/icon. For features, values, team.
        - process: Numbered circles + connectors. For workflows.
        - timeline: Horizontal timeline. For roadmaps, milestones.
        - blank: Empty slide with optional positioned images.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "spec": JSONSchema.string(description: """
                JSON slide spec. Example (a WELL-DESIGNED 10-slide deck with images):
                {
                  "filename": "Q4_Review.pptx",
                  "slides": [
                    {"layout": "title", "content": {"title": "Q4 2024 Review", "subtitle": "Growth & Strategy"}},
                    {"layout": "full_image", "content": {"image_url": "https://images.unsplash.com/photo-...", "title": "Record-Breaking Quarter", "subtitle": "The numbers speak for themselves"}},
                    {"layout": "big_number", "content": {"number": "47%", "label": "Revenue Growth", "body": "Highest quarter in company history"}},
                    {"layout": "cards", "content": {"title": "Key Metrics", "cards": [{"title": "ARR", "body": "$12.4M"}, {"title": "Customers", "body": "1,847"}, {"title": "NPS", "body": "72"}]}},
                    {"layout": "image_right", "content": {"image_url": "https://images.unsplash.com/photo-...", "title": "What Drove Growth", "bullets": ["Expanded to 3 new markets", "Launched enterprise tier", "Reduced churn by 12%"]}},
                    {"layout": "section", "content": {"title": "2025 Strategy"}},
                    {"layout": "process", "content": {"title": "Roadmap", "steps": [{"label": "Q1", "description": "Platform v2"}, {"label": "Q2", "description": "API launch"}, {"label": "Q3", "description": "Enterprise"}, {"label": "Q4", "description": "International"}]}},
                    {"layout": "comparison", "content": {"title": "Old vs New", "left_title": "2024", "left_bullets": ["Manual onboarding", "Single region"], "right_title": "2025", "right_bullets": ["Self-serve", "Global"]}},
                    {"layout": "content", "content": {"title": "Next Steps", "bullets": ["Finalize Q1 hiring plan", "Launch beta program", "Board presentation Feb 15"]}},
                    {"layout": "title", "content": {"title": "Thank You", "subtitle": "Questions?"}}
                  ]
                }
                Notice: 10 slides, 7 different layouts, full_image + image_right for visual impact, \
                big_number for hero metric, cards for grid data, process for roadmap. \
                ALWAYS use search_images first to get real image URLs before creating the spec.
                """),
            "output_dir": JSONSchema.string(description: "Directory to save the file. Default: ~/Desktop"),
        ], required: ["spec"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let specJSON = try requiredString("spec", from: args)
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath

        // Validate spec JSON
        guard let specData = specJSON.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            return "Error: Invalid spec JSON. Must be a JSON object with a 'slides' array."
        }

        guard spec["slides"] != nil else {
            return "Error: Spec must contain a 'slides' array."
        }

        // Extract filename
        let filename = (spec["filename"] as? String) ?? "presentation.pptx"
        let outputPath = (expandedDir as NSString).appendingPathComponent(
            filename.hasSuffix(".pptx") ? filename : filename + ".pptx"
        )

        // Find the PPT engine
        let appSupport = URL.applicationSupportDirectory
        let execDir = appSupport.appendingPathComponent("Executer")
        let enginePath = execDir.appendingPathComponent("ppt_engine.py")

        // Copy from bundle if not in App Support
        PPTExecutor.ensureResource("ppt_engine", ext: "py", in: execDir)
        PPTExecutor.ensureResource("image_utils", ext: "py", in: execDir)

        guard FileManager.default.fileExists(atPath: enginePath.path) else {
            return "Error: ppt_engine.py not found. Reinstall the app."
        }

        // Write spec to temp file
        let tempSpec = FileManager.default.temporaryDirectory.appendingPathComponent("ppt_spec_\(UUID().uuidString).json")
        try specJSON.write(to: tempSpec, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempSpec) }

        // Find best design language: per-file from training > global default
        var engineArgs = ["--spec", tempSpec.path, "--output", outputPath]

        let trainedProfiles = DocumentStudyStore.shared.profiles
            .filter { $0.sourceFormat == "pptx" || $0.sourceFormat == "ppt" }
            .sorted { $0.qualityScore > $1.qualityScore }

        var designFound = false

        // Try per-file design language (matching DocumentTrainer's naming)
        if let best = trainedProfiles.first {
            let safeName = URL(fileURLWithPath: best.sourceFile)
                .deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: " ", with: "_")
            let perFile = execDir.appendingPathComponent("design_language_\(safeName).json")
            if FileManager.default.fileExists(atPath: perFile.path) {
                engineArgs += ["--design", perFile.path]
                designFound = true
            }
        }

        // Fallback: scan for ANY design_language_*.json (pick most recently modified)
        if !designFound {
            if let contents = try? FileManager.default.contentsOfDirectory(at: execDir, includingPropertiesForKeys: [.contentModificationDateKey]),
               let newest = contents
                .filter({ $0.lastPathComponent.hasPrefix("design_language_") && $0.pathExtension == "json" })
                .sorted(by: {
                    let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return d1 > d2
                })
                .first {
                engineArgs += ["--design", newest.path]
                designFound = true
            }
        }

        // Fallback: global design language
        if !designFound {
            let globalDesign = execDir.appendingPathComponent("design_language.json")
            if FileManager.default.fileExists(atPath: globalDesign.path) {
                engineArgs += ["--design", globalDesign.path]
                designFound = true
            }
        }

        // Apply learned design refinements as overrides on top of the design language
        var patchedDesignPath: String?
        if designFound,
           let designArgIdx = engineArgs.firstIndex(of: "--design"),
           designArgIdx + 1 < engineArgs.count {
            let originalDesignPath = engineArgs[designArgIdx + 1]
            if let patched = DesignRefinementStore.shared.patchDesignLanguage(originalPath: originalDesignPath) {
                patchedDesignPath = patched
                engineArgs[designArgIdx + 1] = patched
            }
        }
        defer { if let p = patchedDesignPath { try? FileManager.default.removeItem(atPath: p) } }

        // Find Python (prefer managed venv)
        let python = PPTExecutor.findPython()

        // Run engine
        let result = try await PPTExecutor.runPython(
            python: python,
            script: enginePath.path,
            args: engineArgs
        )

        // Parse result
        if let resultData = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
           let success = json["success"] as? Bool {
            if success {
                let slideCount = json["slides"] as? Int ?? 0
                let path = json["path"] as? String ?? outputPath
                let designNote = designFound
                    ? " (trained design language applied)"
                    : " ⚠️ No trained design language found — using default style. Ask the user to train on a .pptx they like using extract_ppt_design for better results."
                var msg = "Created \(filename) with \(slideCount) slides at \(path)\(designNote)"
                // Surface advisor feedback to the LLM so it can learn from issues
                if let notes = json["advisor_notes"] as? [String], !notes.isEmpty {
                    msg += "\n\nSpec advisor notes (auto-fixed):\n" + notes.map { "- \($0)" }.joined(separator: "\n")
                }

                // Fire-and-forget post-creation reflection — learn from this PPT
                let reflectionPath = path
                Task.detached(priority: .utility) {
                    await PPTReflectionEngine.shared.reflect(generatedPath: reflectionPath)
                }

                return msg
            } else {
                let error = json["error"] as? String ?? "Unknown error"
                return "PPT creation failed: \(error)"
            }
        }

        // If we can't parse JSON but file exists, it probably worked
        if FileManager.default.fileExists(atPath: outputPath) {
            return "Created \(filename) at \(outputPath)"
        }

        // Report error with stderr
        if !result.stderr.isEmpty {
            return "PPT creation failed: \(result.stderr.prefix(300))"
        }

        return "PPT creation failed: No output from engine"
    }
}

/// Tool: extract_ppt_design — Extracts design language from a .pptx for future use.
struct ExtractPPTDesignTool: ToolDefinition {
    let name = "extract_ppt_design"
    let description = "Extract the complete design language (colors, fonts, sizes, layout patterns) from an existing .pptx and save it. Future presentations will use this style automatically."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "input_path": JSONSchema.string(description: "Path to the .pptx file to analyze"),
        ], required: ["input_path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("input_path", from: args)
        let path = NSString(string: rawPath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: path) else {
            return "Error: File not found at \(path)"
        }

        let appSupport = URL.applicationSupportDirectory
        let execDir = appSupport.appendingPathComponent("Executer")
        let extractorPath = execDir.appendingPathComponent("ppt_design_extractor.py")

        guard FileManager.default.fileExists(atPath: extractorPath.path) else {
            return "Error: ppt_design_extractor.py not found. Reinstall the app."
        }

        let outputBase = execDir.appendingPathComponent("design_language")
        let python = PPTExecutor.findPython()

        let result = try await PPTExecutor.runPython(
            python: python,
            script: extractorPath.path,
            args: [path, "-o", outputBase.path, "--format", "both"]
        )

        let jsonPath = outputBase.appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: jsonPath.path) {
            // Count what was extracted
            if let data = try? Data(contentsOf: jsonPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ds = json["design_system"] as? [String: Any] {
                let colors = (ds["color_palette"] as? [[String: Any]])?.count ?? 0
                let fonts = (ds["typography"] as? [String: Any])?["fonts_by_frequency"] as? [[String: Any]]
                let fontCount = fonts?.count ?? 0
                let slides = json["total_slides"] as? Int ?? 0

                return "Extracted design language from \(URL(fileURLWithPath: path).lastPathComponent): \(slides) slides analyzed, \(colors) colors, \(fontCount) fonts. Saved to design_language.json. Future presentations will use this style."
            }
            return "Design language extracted and saved."
        }

        if !result.stderr.isEmpty {
            return "Extraction failed: \(result.stderr.prefix(300))"
        }

        return "Extraction failed: No output file generated."
    }
}

// MARK: - Word Document Creation

struct CreateWordDocumentTool: ToolDefinition {
    let name = "create_word_document"
    let description = """
        Create a Word (.docx) document with headings, paragraphs, bullet lists, numbered lists, tables, and images. \
        Images can be inserted from URLs (auto-downloaded) or local paths. Supports custom fonts, margins, and styling.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "spec": JSONSchema.string(description: """
                JSON document specification:
                {
                  "filename": "report.docx",
                  "sections": [
                    {"heading": "Title", "level": 0, "body": "Introduction text..."},
                    {"heading": "Chapter 1", "level": 1, "body": "Content...", "bullets": ["Point 1", "Point 2"]},
                    {"heading": "Photo Section", "level": 1, "image": {"url": "https://example.com/photo.jpg", "width": 5.0, "alignment": "center", "caption": "Figure 1: Example"}},
                    {"heading": "Data", "level": 1, "table": {"headers": ["Name", "Score"], "rows": [["Alice", "95"]]}}
                  ],
                  "style": {"font": "Times New Roman", "heading_font": "Helvetica Neue", "font_size": 12}
                }
                Image fields: url or path (required), width in inches (default 5), height in inches (auto if omitted), alignment (center/left/right), caption (optional).
                Use search_images tool first to find relevant image URLs.
                """),
            "output_dir": JSONSchema.string(description: "Directory to save the file. Default: ~/Desktop"),
        ], required: ["spec"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let specJSON = try requiredString("spec", from: args)
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath

        guard let specData = specJSON.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            return "Error: Invalid spec JSON."
        }

        let filename = (spec["filename"] as? String) ?? "document.docx"
        let outputPath = (expandedDir as NSString).appendingPathComponent(
            filename.hasSuffix(".docx") ? filename : filename + ".docx"
        )

        let appSupport = URL.applicationSupportDirectory
        let execDir = appSupport.appendingPathComponent("Executer")
        let enginePath = execDir.appendingPathComponent("docx_engine.py")

        PPTExecutor.ensureResource("docx_engine", ext: "py", in: execDir)
        PPTExecutor.ensureResource("image_utils", ext: "py", in: execDir)

        guard FileManager.default.fileExists(atPath: enginePath.path) else {
            return "Error: docx_engine.py not found."
        }

        let tempSpec = FileManager.default.temporaryDirectory.appendingPathComponent("docx_spec_\(UUID().uuidString).json")
        try specJSON.write(to: tempSpec, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempSpec) }

        let python = PPTExecutor.findPython()
        let result = try await PPTExecutor.runPython(python: python, script: enginePath.path,
                                                      args: ["--spec", tempSpec.path, "--output", outputPath])

        if let data = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool, success {
            let sections = json["sections"] as? Int ?? 0
            return "Created \(filename) with \(sections) sections at \(json["path"] as? String ?? outputPath)"
        }

        if FileManager.default.fileExists(atPath: outputPath) { return "Created \(filename) at \(outputPath)" }
        return "DOCX creation failed: \(result.stderr.prefix(300))"
    }
}

// MARK: - Spreadsheet Creation

struct CreateSpreadsheetTool: ToolDefinition {
    let name = "create_spreadsheet"
    let description = """
        Create an Excel (.xlsx) spreadsheet with multiple sheets, headers, data rows, styling, \
        formulas, auto-sized columns, and images. Images can be inserted from URLs or local paths.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "spec": JSONSchema.string(description: """
                JSON spreadsheet specification:
                {
                  "filename": "data.xlsx",
                  "sheets": [
                    {
                      "name": "Grades",
                      "headers": ["Student", "Math", "Science", "Average"],
                      "rows": [["Alice", 95, 88, "=AVERAGE(B2,C2)"], ["Bob", 82, 91, "=AVERAGE(B3,C3)"]],
                      "column_widths": [20, 10, 10, 12],
                      "header_style": {"bold": true, "bg_color": "#0066CC", "font_color": "#FFFFFF"},
                      "images": [{"url": "https://example.com/chart.png", "cell": "F2", "width": 400, "height": 300}]
                    }
                  ]
                }
                Image fields: url or path (required), cell anchor (default "A1"), width/height in pixels.
                Use search_images tool first to find relevant image URLs.
                """),
            "output_dir": JSONSchema.string(description: "Directory to save the file. Default: ~/Desktop"),
        ], required: ["spec"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let specJSON = try requiredString("spec", from: args)
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath

        guard let specData = specJSON.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            return "Error: Invalid spec JSON."
        }

        let filename = (spec["filename"] as? String) ?? "spreadsheet.xlsx"
        let outputPath = (expandedDir as NSString).appendingPathComponent(
            filename.hasSuffix(".xlsx") ? filename : filename + ".xlsx"
        )

        let appSupport = URL.applicationSupportDirectory
        let execDir = appSupport.appendingPathComponent("Executer")
        let enginePath = execDir.appendingPathComponent("xlsx_engine.py")

        PPTExecutor.ensureResource("xlsx_engine", ext: "py", in: execDir)
        PPTExecutor.ensureResource("image_utils", ext: "py", in: execDir)

        guard FileManager.default.fileExists(atPath: enginePath.path) else {
            return "Error: xlsx_engine.py not found."
        }

        let tempSpec = FileManager.default.temporaryDirectory.appendingPathComponent("xlsx_spec_\(UUID().uuidString).json")
        try specJSON.write(to: tempSpec, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempSpec) }

        let python = PPTExecutor.findPython()
        let result = try await PPTExecutor.runPython(python: python, script: enginePath.path,
                                                      args: ["--spec", tempSpec.path, "--output", outputPath])

        if let data = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool, success {
            let sheets = json["sheets"] as? Int ?? 0
            return "Created \(filename) with \(sheets) sheet(s) at \(json["path"] as? String ?? outputPath)"
        }

        if FileManager.default.fileExists(atPath: outputPath) { return "Created \(filename) at \(outputPath)" }
        return "XLSX creation failed: \(result.stderr.prefix(300))"
    }
}

// MARK: - PPT Executor Helpers

enum PPTExecutor {
    struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Copy a Python resource from the app bundle to the Executer App Support directory.
    /// Always overwrites to ensure the latest version is used after app updates.
    static func ensureResource(_ name: String, ext: String, in dir: URL) {
        let dest = dir.appendingPathComponent("\(name).\(ext)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let bundled = Bundle.main.url(forResource: name, withExtension: ext) {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: bundled, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }

    /// Required Python packages for document engines.
    private static let requiredPackages = [
        // Document engines
        "python-pptx", "python-docx", "openpyxl",
        // PDF processing (PyMuPDF is far superior to PyPDF2 — text extraction, splitting, merging, OCR-ready)
        "PyPDF2", "PyMuPDF", "pdfplumber",
        // Image processing
        "Pillow",
        // Data analysis
        "pandas", "numpy", "matplotlib",
        // Web & parsing
        "requests", "beautifulsoup4", "lxml", "html2text",
        // Formats & serialization
        "pyyaml", "tabulate", "Jinja2", "chardet",
        // Vector DB (existing)
        "chromadb",
    ]

    /// Cached python path — detected once, reused.
    private static var cachedPythonPath: String?

    /// Whether the venv has already been ensured this session.
    private static var venvReady = false

    static func findPython() -> String {
        if let cached = cachedPythonPath { return cached }

        let appSupport = URL.applicationSupportDirectory
        let venvDir = appSupport.appendingPathComponent("Executer/python_env")
        let venvPython = venvDir.appendingPathComponent("bin/python3").path

        // Auto-provision the managed venv if it doesn't exist
        if !FileManager.default.isExecutableFile(atPath: venvPython) {
            setupVenv(at: venvDir)
        } else if !venvReady {
            // Venv exists — verify packages on first use this session
            ensurePackages(venvDir: venvDir)
        }

        let candidates = [
            venvPython,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPythonPath = path
                return path
            }
        }
        cachedPythonPath = "python3"
        return "python3"
    }

    /// Create a managed Python venv and install all document dependencies (python-pptx, etc.).
    private static func setupVenv(at venvDir: URL) {
        print("[PPTExecutor] Setting up Python venv with document dependencies...")

        // Find system python
        let systemPython: String
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") {
            systemPython = "/opt/homebrew/bin/python3"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/python3") {
            systemPython = "/usr/local/bin/python3"
        } else {
            systemPython = "/usr/bin/python3"
        }

        // Create venv
        let venvProcess = Process()
        venvProcess.executableURL = URL(fileURLWithPath: systemPython)
        venvProcess.arguments = ["-m", "venv", venvDir.path]
        try? venvProcess.run()
        venvProcess.waitUntilExit()

        let venvPython = venvDir.appendingPathComponent("bin/python3").path
        guard FileManager.default.isExecutableFile(atPath: venvPython) else {
            print("[PPTExecutor] Failed to create Python venv")
            return
        }

        // Install all required packages
        let pipPath = venvDir.appendingPathComponent("bin/pip3").path
        let pipProcess = Process()
        pipProcess.executableURL = URL(fileURLWithPath: pipPath)
        pipProcess.arguments = ["install"] + requiredPackages
        pipProcess.standardOutput = FileHandle.nullDevice
        pipProcess.standardError = FileHandle.nullDevice
        try? pipProcess.run()
        pipProcess.waitUntilExit()

        if pipProcess.terminationStatus == 0 {
            print("[PPTExecutor] Python dependencies installed successfully")
            venvReady = true
        } else {
            print("[PPTExecutor] pip install failed (exit \(pipProcess.terminationStatus))")
        }
    }

    /// Fingerprint of the current required packages list — changes when packages are added/removed.
    /// Stored in the venv dir to detect when the package set has been updated.
    private static var packageFingerprint: String {
        // Sort for stability, then hash — any change to requiredPackages triggers reinstall
        requiredPackages.sorted().joined(separator: ",")
    }

    /// Quick check that required packages are importable; install missing ones.
    private static func ensurePackages(venvDir: URL) {
        let venvPython = venvDir.appendingPathComponent("bin/python3").path
        let fingerprintFile = venvDir.appendingPathComponent(".pkg_fingerprint").path

        // Fast path: if fingerprint matches, we already installed this exact package set
        if let stored = try? String(contentsOfFile: fingerprintFile, encoding: .utf8),
           stored.trimmingCharacters(in: .whitespacesAndNewlines) == packageFingerprint {
            venvReady = true
            return
        }

        // Fingerprint mismatch or missing — verify key packages (old + new)
        let checkProcess = Process()
        let pipe = Pipe()
        checkProcess.executableURL = URL(fileURLWithPath: venvPython)
        checkProcess.arguments = ["-c",
            "import pptx; import docx; import openpyxl; import fitz; import pandas; import numpy; import matplotlib; import pdfplumber; print('OK')"
        ]
        checkProcess.standardOutput = pipe
        checkProcess.standardError = FileHandle.nullDevice
        try? checkProcess.run()
        checkProcess.waitUntilExit()

        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if out.contains("OK") {
            // All good — write fingerprint so we skip next time
            try? packageFingerprint.write(toFile: fingerprintFile, atomically: true, encoding: .utf8)
            venvReady = true
            return
        }

        // Some packages missing — install them all (pip handles already-installed gracefully)
        print("[PPTExecutor] Installing missing Python packages...")
        let pipPath = venvDir.appendingPathComponent("bin/pip3").path
        let pipProcess = Process()
        pipProcess.executableURL = URL(fileURLWithPath: pipPath)
        pipProcess.arguments = ["install", "--quiet"] + requiredPackages
        pipProcess.standardOutput = FileHandle.nullDevice
        pipProcess.standardError = FileHandle.nullDevice
        try? pipProcess.run()
        pipProcess.waitUntilExit()

        if pipProcess.terminationStatus == 0 {
            try? packageFingerprint.write(toFile: fingerprintFile, atomically: true, encoding: .utf8)
        }
        venvReady = true
    }

    /// Install additional pip packages into the managed venv on demand.
    static func installPackages(_ packages: [String]) async throws {
        let _ = findPython() // ensure venv exists
        let appSupport = URL.applicationSupportDirectory
        let pipPath = appSupport.appendingPathComponent("Executer/python_env/bin/pip3").path

        guard FileManager.default.isExecutableFile(atPath: pipPath) else {
            print("[PPTExecutor] pip3 not found in managed venv")
            return
        }

        // Sanitize package names
        let safe = packages.compactMap { pkg -> String? in
            let cleaned = pkg.replacingOccurrences(of: "[^a-zA-Z0-9._@/\\-]", with: "", options: .regularExpression)
            return cleaned.isEmpty ? nil : cleaned
        }
        guard !safe.isEmpty else { return }

        let result = try await AsyncShellRunner.run(
            executable: pipPath,
            arguments: ["install", "--quiet"] + safe,
            timeout: 120
        )
        if result.exitCode == 0 {
            print("[PPTExecutor] Installed packages: \(safe.joined(separator: ", "))")
        } else {
            print("[PPTExecutor] pip install failed: \(result.stderr.prefix(200))")
        }
    }

    static func runPython(python: String, script: String, args: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = [script] + args
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = ProcessInfo.processInfo.environment.merging([
                    "PYTHONIOENCODING": "utf-8",
                    "PYTHONUNBUFFERED": "1",
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
                ]) { _, new in new }

                do {
                    try process.run()
                    // Read pipes BEFORE waitUntilExit to avoid deadlock when output exceeds pipe buffer (~64KB)
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(returning: ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
