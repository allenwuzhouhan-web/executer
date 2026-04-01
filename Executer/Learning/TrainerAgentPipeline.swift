import Foundation

/// 8-stage deep analysis pipeline for document training.
///
/// analyze1 (content) → analyze2 (structure) → analyze3 (design) →
/// learn1 (design principles) → learn2 (content placement) →
/// optimize1 (refine all) → checker1 (catch misses) → presenter (final output)
///
/// Each stage gets ALL previous stages' output as accumulated context.
/// Uses Gemini Flash dedicated service — does not touch user's main LLM.
final class TrainerAgentPipeline {

    private var trainerService: LLMServiceProtocol {
        if APIKeyManager.shared.getKey(for: .gemini) != nil {
            return OpenAICompatibleService(provider: .gemini, model: "gemini-2.5-flash")
        }
        return LLMServiceManager.shared.currentService
    }

    // MARK: - Pipeline Entry

    func analyze(
        content: String,
        styleJSON: String?,
        filename: String,
        format: String,
        fileSize: Int,
        onProgress: @MainActor @escaping (String) -> Void
    ) async throws -> DocumentStudyProfile {

        // Feed the FULL content to the pipeline — don't truncate early
        let fullContent = content
        let style = styleJSON ?? ""

        // Stage 1: analyze1 — CONTENT (what is this about?)
        await onProgress("[1/8] Analyzing content...")
        let stage1 = try await runStage(
            name: "analyze1",
            instruction: """
                You are a content analyst. Read this \(format.uppercased()) document "\(filename)" and extract EVERY piece of content.

                For EACH slide/section, list:
                - Slide/section number and title
                - ALL text content (quotes, bullets, body text — miss NOTHING)
                - Key terms and their definitions
                - Data points, statistics, dates mentioned
                - Any questions or discussion prompts

                Be EXHAUSTIVE. Copy important text verbatim. This is the foundation — anything you miss here is lost forever.
                """,
            input: "DOCUMENT CONTENT:\n\(fullContent.prefix(28000))",
            prevContext: ""
        )

        // Stage 2: analyze2 — STRUCTURE (how is it organized?)
        await onProgress("[2/8] Analyzing structure...")
        let stage2 = try await runStage(
            name: "analyze2",
            instruction: """
                You are a structural analyst. Based on the content analysis, map the document's architecture:

                - Total sections/slides count
                - Full hierarchy (outline with nesting levels)
                - Flow pattern: how does the argument/narrative progress?
                - Section transitions: how does each section connect to the next?
                - Content density per section (sparse/moderate/dense)
                - Information architecture: what's the intro → body → conclusion structure?
                """,
            input: "DOCUMENT CONTENT:\n\(fullContent.prefix(15000))",
            prevContext: "CONTENT ANALYSIS:\n\(stage1)"
        )

        // Stage 3: analyze3 — DESIGN (visual and layout)
        await onProgress("[3/8] Analyzing design...")
        let stage3 = try await runStage(
            name: "analyze3",
            instruction: """
                You are a visual design analyst. Analyze the document's design language:

                - Fonts used (heading vs body, sizes, weights)
                - Color palette (primary, secondary, accent colors)
                - Layout patterns (margins, alignment, spacing)
                - Visual hierarchy (how is importance communicated visually?)
                - Recurring design elements (accent bars, dividers, icons, shapes)
                - Slide/page templates used and their variations
                - White space usage
                - Consistency score: how consistent is the design across sections?
                \(style.isEmpty ? "" : "\n\nSTYLE METADATA (extracted from file):\n\(style.prefix(5000))")
                """,
            input: "DOCUMENT CONTENT:\n\(fullContent.prefix(10000))",
            prevContext: "CONTENT ANALYSIS:\n\(stage1.prefix(3000))\n\nSTRUCTURE ANALYSIS:\n\(stage2)"
        )

        // Stage 4: learn1 — DESIGN PRINCIPLES (how to design like this)
        await onProgress("[4/8] Learning design principles...")
        let stage4 = try await runStage(
            name: "learn1",
            instruction: """
                You are a design teacher. Based on all the analysis so far, extract the DESIGN RULES that make this document work (or not work):

                - Typography rules: "Titles are X pt bold, body is Y pt regular"
                - Color rules: "Primary accent is used for headers, secondary for highlights"
                - Layout rules: "Content is left-aligned with 5% margin, titles are centered"
                - Spacing rules: "Bullets have 1.2x line spacing, sections have 2x gap"
                - Visual hierarchy rules: "3 levels: title (large bold) → subtitle (medium) → body (small)"
                - What makes this design GOOD or BAD? Be specific.
                - What would you change to improve it?

                Format as actionable rules someone could follow to recreate this style.
                """,
            input: "",
            prevContext: "CONTENT:\n\(stage1.prefix(2000))\n\nSTRUCTURE:\n\(stage2.prefix(2000))\n\nDESIGN:\n\(stage3)"
        )

        // Stage 5: learn2 — CONTENT PLACEMENT (what goes where)
        await onProgress("[5/8] Learning content placement...")
        let stage5 = try await runStage(
            name: "learn2",
            instruction: """
                You are a presentation coach. Based on everything analyzed, teach me the CONTENT PLACEMENT PATTERNS:

                - What type of content goes on each type of slide? (title slide has X, content slide has Y)
                - How many bullets per slide? How long is each bullet?
                - Where does the main argument/thesis appear?
                - How are examples, evidence, and data presented?
                - What's the ratio of text to visuals?
                - How are transitions between topics handled?
                - What's the pacing? (how much info per slide)
                - What content patterns repeat? (e.g., "claim → evidence → conclusion" on each slide)

                Be specific with examples from the actual document.
                """,
            input: "",
            prevContext: "CONTENT:\n\(stage1.prefix(3000))\n\nSTRUCTURE:\n\(stage2.prefix(2000))\n\nDESIGN:\n\(stage3.prefix(2000))\n\nDESIGN RULES:\n\(stage4.prefix(2000))"
        )

        // Stage 6: optimize1 — REFINE (synthesize and optimize all findings)
        await onProgress("[6/8] Optimizing analysis...")
        let stage6 = try await runStage(
            name: "optimize1",
            instruction: """
                You are a quality optimizer. Review ALL previous analysis stages and:

                1. Resolve any CONTRADICTIONS between stages
                2. Fill GAPS — what did the earlier stages skip or underanalyze?
                3. Strengthen weak conclusions with better evidence from the content
                4. Create a UNIFIED assessment:
                   - Overall quality score (0-100, be honest)
                   - Top 5 strengths of this document
                   - Top 5 weaknesses
                   - Audience level: introductory/intermediate/advanced/expert
                   - Domain classification
                   - Teaching approach used
                5. Produce a REFINED key terms list with definitions
                """,
            input: "",
            prevContext: """
                CONTENT ANALYSIS:\n\(stage1.prefix(3000))
                STRUCTURE:\n\(stage2.prefix(2000))
                DESIGN:\n\(stage3.prefix(2000))
                DESIGN RULES:\n\(stage4.prefix(2000))
                CONTENT PLACEMENT:\n\(stage5.prefix(2000))
                """
        )

        // Stage 7: checker1 — FINAL CHECK (catch anything missed)
        await onProgress("[7/8] Final check for missed content...")
        let stage7 = try await runStage(
            name: "checker1",
            instruction: """
                You are a meticulous fact-checker. Go back to the ORIGINAL document content and compare it against all the analysis.

                Find ANYTHING that was:
                - Mentioned in the document but NOT captured in the analysis
                - Misquoted or paraphrased incorrectly
                - Important but marked as supplementary
                - A key term that was missed entirely
                - A structural pattern that was overlooked

                Also flag:
                - Content that seems incorrect or misleading in the source document
                - Sections that are confusingly written in the source

                List every finding. If everything was captured perfectly, say so explicitly.
                """,
            input: "ORIGINAL DOCUMENT:\n\(fullContent.prefix(20000))",
            prevContext: "OPTIMIZED ANALYSIS:\n\(stage6)"
        )

        // Stage 8: presenter — FINAL PRESENTATION (leveled bullet summary)
        await onProgress("[8/8] Composing final summary...")
        let stage8 = try await runStage(
            name: "presenter",
            instruction: """
                You are the final presenter. Using ALL 7 stages of analysis, produce the definitive summary.

                You MUST respond with ONLY this JSON (no other text):
                {
                    "oneLiner": "One sentence capturing what this document IS and what it teaches.",
                    "qualityScore": <0-100 integer>,
                    "qualityNotes": "Brief assessment of document quality as a learning resource.",
                    "domain": "The subject domain (e.g., literature, chemistry, history)",
                    "audienceLevel": "introductory|intermediate|advanced|expert",
                    "teachingApproach": "How the document teaches (example-driven, visual, etc.)",
                    "mainTopic": "The primary topic",
                    "subtopics": ["subtopic1", "subtopic2"],
                    "totalSections": <int>,
                    "flowPattern": "How the content flows",
                    "keyTerms": [{"term": "...", "definition": "..."}],
                    "keyTakeaways": ["Most important fact 1", "Most important fact 2"],
                    "designRules": ["Rule 1: Titles are 40pt bold", "Rule 2: Accent color #0066CC"],
                    "contentPlacement": ["Pattern 1: Each slide has title + 3 bullets", "Pattern 2: Evidence follows claims"],
                    "strengths": ["Strength 1", "Strength 2"],
                    "weaknesses": ["Weakness 1", "Weakness 2"],
                    "missedItems": ["Anything checker found that was missing"],
                    "bullets": [
                        {"level": 0, "text": "Top-level theme or key section", "importance": "critical"},
                        {"level": 1, "text": "Key point within the theme", "importance": "important"},
                        {"level": 2, "text": "Supporting detail", "importance": "supplementary"}
                    ],
                    "studyRecommendation": "What to focus on when studying this document."
                }

                Include AT LEAST 15 bullets covering all major content from the document.
                Every key fact should appear as a bullet. Do NOT be brief — be COMPREHENSIVE.
                """,
            input: "",
            prevContext: """
                CONTENT:\n\(stage1.prefix(4000))
                STRUCTURE:\n\(stage2.prefix(2000))
                DESIGN:\n\(stage3.prefix(2000))
                DESIGN RULES:\n\(stage4.prefix(2000))
                CONTENT PLACEMENT:\n\(stage5.prefix(2000))
                OPTIMIZED:\n\(stage6.prefix(3000))
                CHECKER FINDINGS:\n\(stage7.prefix(2000))
                """
        )

        return buildProfile(presenterRaw: stage8, filename: filename, format: format, fileSize: fileSize,
                           rawStages: [stage1, stage2, stage3, stage4, stage5, stage6, stage7],
                           styleJSON: style)
    }

    // MARK: - Stage Runner

    private func runStage(name: String, instruction: String, input: String, prevContext: String) async throws -> String {
        let systemPrompt = instruction
        var userMessage = ""
        if !prevContext.isEmpty { userMessage += "PREVIOUS ANALYSIS:\n\(prevContext)\n\n" }
        if !input.isEmpty { userMessage += input }
        if userMessage.isEmpty { userMessage = "Proceed with the analysis based on the system instructions." }

        let result = try await callLLM(system: systemPrompt, user: userMessage, maxTokens: 4096)
        print("[Trainer] Stage \(name): \(result.count) chars")
        return result
    }

    private func callLLM(system: String, user: String, maxTokens: Int) async throws -> String {
        let messages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: user)
        ]
        let service = trainerService
        let response = try await service.sendChatRequest(messages: messages, tools: nil, maxTokens: maxTokens)
        guard let text = response.text, !text.isEmpty else { throw TrainerError.emptyResponse }
        return text
    }

    // MARK: - Profile Builder

    private func buildProfile(presenterRaw: String, filename: String, format: String, fileSize: Int,
                              rawStages: [String], styleJSON: String? = nil) -> DocumentStudyProfile {
        // Try to decode presenter JSON
        let presenter = decodeFlexible(PresenterOutput.self, from: presenterRaw)

        print("[Trainer] Presenter decoded: \(presenter != nil)")
        if presenter == nil {
            print("[Trainer] Raw presenter preview: \(presenterRaw.prefix(500))")
        }

        let quality = Double(presenter?.qualityScore ?? extractInt(from: presenterRaw, field: "qualityScore") ?? 50) / 100.0

        // Build bullets — from presenter, or extract from raw stages
        var bullets = presenter?.bullets ?? []
        if bullets.isEmpty {
            bullets = extractBulletsFromRaw(presenterRaw)
        }
        if bullets.isEmpty {
            // Last resort: turn key takeaways or raw stage content into bullets
            let takeaways = presenter?.keyTakeaways ?? extractArray(from: presenterRaw, field: "keyTakeaways")
            bullets = takeaways.enumerated().map { i, t in
                LeveledBullet(level: 0, text: t, importance: i < 3 ? "critical" : "important")
            }
        }

        let keyTerms = presenter?.keyTerms ?? []

        // Parse design extractor JSON for structured style data
        var parsedPrimaryFont: String?
        var parsedHeadingFont: String?
        var parsedFontSize: String?
        var parsedColorScheme: [String] = []
        var parsedVisualDensity = "moderate"
        var parsedLayoutNotes: String?

        if let styleData = styleJSON?.data(using: .utf8),
           let styleDict = try? JSONSerialization.jsonObject(with: styleData) as? [String: Any] {
            let ds = styleDict["design_system"] as? [String: Any] ?? [:]

            // Colors from semantic_colors (preferred)
            if let semantic = ds["semantic_colors"] as? [String: String] {
                for (role, hex) in semantic.sorted(by: { $0.key < $1.key }) {
                    parsedColorScheme.append("\(role):\(hex)")
                }
            }
            // Fallback: raw palette
            if parsedColorScheme.isEmpty, let palette = ds["color_palette"] as? [[String: Any]] {
                parsedColorScheme = palette.prefix(8).compactMap { $0["hex"] as? String }
            }

            // Typography
            if let typo = ds["typography"] as? [String: Any],
               let fonts = typo["fonts_by_frequency"] as? [[String: Any]] {
                parsedPrimaryFont = fonts.first?["font"] as? String
                parsedHeadingFont = fonts.count > 1 ? (fonts[1]["font"] as? String) : parsedPrimaryFont
            }
            if let hierarchy = ds["text_hierarchy"] as? [[String: Any]] {
                parsedFontSize = hierarchy.compactMap { item -> String? in
                    guard let role = item["likely_role"] as? String, let size = item["size_pt"] else { return nil }
                    return "\(role):\(size)pt"
                }.joined(separator: ", ")
            }

            // Design philosophy → visual density + layout notes
            if let dp = styleDict["design_philosophy"] as? [String: Any] {
                if let density = dp["content_density"] as? String {
                    parsedVisualDensity = (density == "minimal" || density == "moderate") ? "sparse" : density
                }
                var notes: [String] = []
                if let density = dp["content_density"] as? String { notes.append("density:\(density)") }
                if let ws = dp["whitespace_style"] as? String { notes.append("whitespace:\(ws)") }
                if let complexity = dp["layout_complexity"] as? String { notes.append("complexity:\(complexity)") }
                if let align = dp["dominant_alignment"] as? String { notes.append("alignment:\(align)") }
                if let restraint = dp["color_restraint"] as? String { notes.append("colors:\(restraint)") }
                parsedLayoutNotes = notes.joined(separator: ", ")
            }
        }

        return DocumentStudyProfile(
            id: UUID(),
            createdAt: Date(),
            sourceFile: filename,
            sourceFormat: format,
            fileSizeBytes: fileSize,
            structure: StructureAnalysis(
                totalSections: presenter?.totalSections ?? extractInt(from: presenterRaw, field: "totalSections") ?? 0,
                hierarchy: [],
                flowPattern: presenter?.flowPattern ?? extractField(from: presenterRaw, field: "flowPattern") ?? "linear",
                avgContentPerSection: "see analysis",
                transitionStyle: nil
            ),
            style: StyleAnalysis(
                primaryFont: parsedPrimaryFont,
                headingFont: parsedHeadingFont,
                fontSize: parsedFontSize,
                colorScheme: parsedColorScheme,
                visualDensity: parsedVisualDensity,
                formattingPatterns: presenter?.designRules ?? extractArray(from: presenterRaw, field: "designRules"),
                layoutNotes: parsedLayoutNotes
            ),
            content: ContentAnalysis(
                mainTopic: presenter?.mainTopic ?? extractField(from: presenterRaw, field: "mainTopic") ?? filename,
                subtopics: presenter?.subtopics ?? extractArray(from: presenterRaw, field: "subtopics"),
                keyTerms: keyTerms,
                audienceLevel: presenter?.audienceLevel ?? extractField(from: presenterRaw, field: "audienceLevel") ?? "intermediate",
                domain: presenter?.domain ?? extractField(from: presenterRaw, field: "domain") ?? "general",
                teachingApproach: presenter?.teachingApproach ?? extractField(from: presenterRaw, field: "teachingApproach") ?? "mixed",
                keyTakeaways: presenter?.keyTakeaways ?? extractArray(from: presenterRaw, field: "keyTakeaways")
            ),
            designPatterns: (presenter?.contentPlacement ?? []).map {
                DesignPattern(name: "Placement", description: $0, frequency: 1, example: nil)
            },
            qualityScore: quality,
            qualityNotes: presenter?.qualityNotes ?? extractField(from: presenterRaw, field: "qualityNotes"),
            summary: LeveledSummary(
                oneLiner: presenter?.oneLiner ?? extractField(from: presenterRaw, field: "oneLiner") ?? "Document analyzed.",
                bullets: bullets,
                studyRecommendation: presenter?.studyRecommendation ?? extractField(from: presenterRaw, field: "studyRecommendation") ?? "Review key terms and takeaways."
            )
        )
    }

    // MARK: - Flexible JSON Decoding

    private func decodeFlexible<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        let decoder = JSONDecoder()

        // Strategy 1: Extract JSON object then decode
        if let json = extractJSONObject(from: raw),
           let data = json.data(using: .utf8),
           let result = try? decoder.decode(type, from: data) {
            return result
        }

        // Strategy 2: Fix trailing commas
        if let json = extractJSONObject(from: raw) {
            let fixed = json
                .replacingOccurrences(of: ",\\s*}", with: "}", options: .regularExpression)
                .replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)
            if let data = fixed.data(using: .utf8),
               let result = try? decoder.decode(type, from: data) {
                return result
            }
        }

        // Strategy 3: Clean markdown fences then decode
        let cleaned = cleanJSON(raw)
        if let data = cleaned.data(using: .utf8),
           let result = try? decoder.decode(type, from: data) {
            return result
        }

        return nil
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let startIdx = text.firstIndex(of: "{") else { return nil }
        var depth = 0; var inString = false; var escape = false
        var endIdx = text.endIndex

        for idx in text.indices[startIdx...] {
            let ch = text[idx]
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1; if depth == 0 { endIdx = text.index(after: idx); break } }
        }
        guard depth == 0 else { return nil }
        return String(text[startIdx..<endIdx])
    }

    private func cleanJSON(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") { s = String(s.dropFirst(7)) }
        else if s.hasPrefix("```") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = s.firstIndex(of: "{"), i != s.startIndex { s = String(s[i...]) }
        return s
    }

    // MARK: - Regex Extraction Fallbacks

    private func extractField(from text: String, field: String) -> String? {
        let pattern = "\"\(field)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func extractInt(from text: String, field: String) -> Int? {
        let pattern = "\"\(field)\"\\s*:\\s*([0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private func extractArray(from text: String, field: String) -> [String] {
        let pattern = "\"\(field)\"\\s*:\\s*\\[([^\\]]+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return [] }
        let inner = String(text[range])
        let itemPattern = "\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern) else { return [] }
        return itemRegex.matches(in: inner, range: NSRange(inner.startIndex..., in: inner)).compactMap {
            Range($0.range(at: 1), in: inner).map { String(inner[$0]) }
        }
    }

    private func extractBulletsFromRaw(_ text: String) -> [LeveledBullet] {
        let pattern = "\"text\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.enumerated().compactMap { i, match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return LeveledBullet(
                level: i < 4 ? 0 : (i < 10 ? 1 : 2),
                text: String(text[range]),
                importance: i < 4 ? "critical" : (i < 10 ? "important" : "supplementary")
            )
        }
    }

    // MARK: - Errors

    enum TrainerError: Error, LocalizedError {
        case emptyResponse
        case extractionFailed(String)
        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "LLM returned empty response"
            case .extractionFailed(let msg): return "Content extraction failed: \(msg)"
            }
        }
    }
}

// MARK: - Presenter Output (matches stage 8 JSON)

private struct PresenterOutput: Codable {
    var oneLiner: String?
    var qualityScore: Int?
    var qualityNotes: String?
    var domain: String?
    var audienceLevel: String?
    var teachingApproach: String?
    var mainTopic: String?
    var subtopics: [String]?
    var totalSections: Int?
    var flowPattern: String?
    var keyTerms: [KeyTerm]?
    var keyTakeaways: [String]?
    var designRules: [String]?
    var contentPlacement: [String]?
    var strengths: [String]?
    var weaknesses: [String]?
    var missedItems: [String]?
    var bullets: [LeveledBullet]?
    var studyRecommendation: String?
}
