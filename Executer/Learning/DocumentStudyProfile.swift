import Foundation

/// Deep analysis profile from studying a reference document.
/// Captures structure, style, content, and design patterns — the "DNA" of a good document.
struct DocumentStudyProfile: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let sourceFile: String              // original filename
    let sourceFormat: String            // pptx, docx, key, pdf, etc.
    let fileSizeBytes: Int

    // MARK: - Structure Analysis
    var structure: StructureAnalysis

    // MARK: - Style Analysis
    var style: StyleAnalysis

    // MARK: - Content Analysis
    var content: ContentAnalysis

    // MARK: - Design Patterns
    var designPatterns: [DesignPattern]

    // MARK: - Quality Assessment
    var qualityScore: Double            // 0.0-1.0 from Critic agent
    var qualityNotes: String?

    // MARK: - Leveled Summary (final Writer output)
    var summary: LeveledSummary
}

// MARK: - Sub-Models

struct StructureAnalysis: Codable {
    var totalSections: Int              // slides for PPTX/KEY, sections for DOCX
    var hierarchy: [HierarchyNode]      // nested outline of the document
    var flowPattern: String             // "linear", "problem-solution", "chronological", "compare-contrast", etc.
    var avgContentPerSection: String    // "~3 bullets per slide", "~200 words per section"
    var transitionStyle: String?        // how sections connect ("numbered", "thematic", "none")
}

struct HierarchyNode: Codable {
    var level: Int                      // 0 = top-level, 1 = sub-section, etc.
    var title: String
    var children: [HierarchyNode]?
    var contentPreview: String?         // first ~50 chars of content
}

struct StyleAnalysis: Codable {
    var primaryFont: String?
    var headingFont: String?
    var fontSize: String?               // "14pt body, 28pt headings"
    var colorScheme: [String]           // hex colors extracted
    var visualDensity: String           // "sparse", "moderate", "dense"
    var formattingPatterns: [String]    // "bold key terms", "italic definitions", "colored headers"
    var layoutNotes: String?            // "two-column", "centered titles", "full-bleed images"
}

struct ContentAnalysis: Codable {
    var mainTopic: String
    var subtopics: [String]
    var keyTerms: [KeyTerm]
    var audienceLevel: String           // "introductory", "intermediate", "advanced", "expert"
    var domain: String                  // "chemistry", "computer science", "business", etc.
    var teachingApproach: String        // "example-driven", "definition-first", "visual", "proof-based"
    var keyTakeaways: [String]          // the actual important facts/concepts
}

struct KeyTerm: Codable {
    var term: String
    var definition: String?
    var context: String?                // where/how it's used in the document
}

struct DesignPattern: Codable {
    var name: String                    // "Problem → Solution → Example", "Definition Box", etc.
    var description: String
    var frequency: Int                  // how often this pattern appears
    var example: String?                // brief example from the document
}

struct LeveledSummary: Codable {
    var oneLiner: String                // 1-sentence TL;DR
    var bullets: [LeveledBullet]        // hierarchical bullet points
    var studyRecommendation: String     // "Focus on X, the Y section is weak"
}

struct LeveledBullet: Codable {
    var level: Int                      // 0 = top, 1 = sub, 2 = detail
    var text: String
    var importance: String              // "critical", "important", "supplementary"
}

// MARK: - Storage Manager

final class DocumentStudyStore {
    static let shared = DocumentStudyStore()

    private let storageDir: URL
    private(set) var profiles: [DocumentStudyProfile] = []

    private init() {
        let appSupport = URL.applicationSupportDirectory
        storageDir = appSupport.appendingPathComponent("Executer/trained_documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        loadAll()
        print("[DocumentStudy] Loaded \(profiles.count) trained document profiles")
    }

    func save(_ profile: DocumentStudyProfile) {
        // Update or append
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(profile) {
            let url = storageDir.appendingPathComponent("\(profile.id.uuidString).json")
            try? data.write(to: url, options: .atomic)
        }
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        let url = storageDir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    func profile(forFile name: String) -> DocumentStudyProfile? {
        profiles.first { $0.sourceFile == name }
    }

    /// Build a prompt section for LLM context. Query-aware: if creating a document,
    /// includes actionable design rules and content placement patterns.
    func promptSection(for query: String = "") -> String {
        guard !profiles.isEmpty else { return "" }

        let lower = query.lowercased()
        let isCreating = ["create", "make", "build", "generate", "presentation", "pptx", "slide",
                          "document", "docx", "word", "spreadsheet", "xlsx", "excel"].contains { lower.contains($0) }

        var lines = ["\n## Trained Document Knowledge"]

        if isCreating {
            // Creation mode: include actionable design rules and placement patterns
            let pptxProfiles = profiles.filter { $0.sourceFormat == "pptx" || $0.sourceFormat == "ppt" }
                .sorted { $0.qualityScore > $1.qualityScore }

            if let best = pptxProfiles.first {
                lines.append("\n### Presentation Design Rules (from \(best.sourceFile), \(Int(best.qualityScore * 100))% quality)")
                for rule in best.style.formattingPatterns.prefix(8) {
                    lines.append("- \(rule)")
                }
                // Content placement patterns stored in designPatterns
                if !best.designPatterns.isEmpty {
                    lines.append("\n### Content Placement Patterns")
                    for pattern in best.designPatterns.prefix(6) {
                        lines.append("- \(pattern.description)")
                    }
                }

                // Load design philosophy from design_language.json if available
                let appSupport = URL.applicationSupportDirectory
                let execDir = appSupport.appendingPathComponent("Executer")
                let globalDesign = execDir.appendingPathComponent("design_language.json")
                if let data = try? Data(contentsOf: globalDesign),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dp = json["design_philosophy"] as? [String: Any] {
                    lines.append("\n### User's Design Philosophy (extracted from their presentations)")
                    if let density = dp["content_density"] as? String {
                        lines.append("- Content density: \(density) — \(density == "minimal" ? "use FEW words per slide, let whitespace do the work" : density == "moderate" ? "concise text, not too sparse" : "more text is acceptable")")
                    }
                    if let ws = dp["whitespace_style"] as? String {
                        lines.append("- Whitespace: \(ws) — \(ws == "airy" ? "this user values breathing room, use generous margins" : ws == "balanced" ? "standard spacing" : "content takes priority over whitespace")")
                    }
                    if let complexity = dp["layout_complexity"] as? String {
                        lines.append("- Layout complexity: \(complexity) — \(complexity == "minimal" ? "very few shapes per slide, simplicity is key" : complexity == "clean" ? "clean layouts with purposeful elements only" : "denser layouts acceptable")")
                    }
                    if let align = dp["dominant_alignment"] as? String {
                        lines.append("- Text alignment: predominantly \(align)")
                    }
                    if let restraint = dp["color_restraint"] as? String {
                        lines.append("- Color palette: \(restraint) — \(restraint == "monochrome" || restraint == "restrained" ? "this user keeps color MINIMAL, do NOT introduce extra colors" : "broader palette is fine")")
                    }
                    if let effects = dp["effects_usage"] as? [String: String] {
                        let shadowUse = effects["shadows"] ?? "none"
                        let gradientUse = effects["gradients"] ?? "none"
                        if shadowUse == "none" && gradientUse == "none" {
                            lines.append("- Visual effects: NONE — this user designs without shadows or gradients. Do NOT add any. Clean and flat is the style.")
                        } else {
                            lines.append("- Shadows: \(shadowUse), Gradients: \(gradientUse)")
                        }
                    }

                    // Inject visual effects details
                    if let ve = json["visual_effects"] as? [String: Any] {
                        if let hasShadows = ve["has_shadows"] as? Bool, hasShadows,
                           let style = ve["shadow_style"] as? [String: Any] {
                            let blur = style["blur_pt"] as? Double ?? 4
                            let offset = style["offset_pt"] as? Double ?? 2
                            let alpha = style["alpha_pct"] as? Double ?? 25
                            lines.append("- Shadow style: blur \(blur)pt, offset \(offset)pt, \(alpha)% opacity — the engine reproduces this exactly")
                        }
                        if let hasRounded = ve["has_rounded_corners"] as? Bool, hasRounded,
                           let radius = ve["corner_radius_pct"] as? Double {
                            lines.append("- Corner radius: \(radius)% — rounded corners applied automatically by the engine")
                        }
                        if let angles = ve["gradient_angles"] as? [Int], !angles.isEmpty {
                            lines.append("- Gradient direction: \(angles.map { "\($0)°" }.joined(separator: ", "))")
                        }
                    }
                }

                lines.append("\nWhen creating presentations, use create_presentation with the JSON spec format.")
                lines.append("The PPT engine will auto-apply the saved design language (fonts, colors, layout, shadows, corner radius).")
                lines.append("CRITICAL: Match the user's design philosophy above. If they use minimal/clean design, do NOT over-decorate.")
                lines.append("Think like Apple: every element serves a purpose. No decoration without function. Generous whitespace. Typography does the heavy lifting.")
            }
        }

        // Always include summaries
        for p in profiles.suffix(8) {
            lines.append("### \(p.sourceFile) (\(p.sourceFormat))")
            lines.append(p.summary.oneLiner)
            let bulletLimit = isCreating ? 3 : 5
            for bullet in p.summary.bullets.prefix(bulletLimit) {
                let indent = String(repeating: "  ", count: bullet.level)
                let marker = bullet.importance == "critical" ? "**" : ""
                lines.append("\(indent)- \(marker)\(bullet.text)\(marker)")
            }
        }

        var result = lines.joined(separator: "\n")
        if result.count > 4000 { result = String(result.prefix(4000)) + "\n(truncated)" }
        return result
    }

    private func loadAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let profile = try? decoder.decode(DocumentStudyProfile.self, from: data) {
                profiles.append(profile)
            }
        }
        profiles.sort { $0.createdAt > $1.createdAt }
    }
}
