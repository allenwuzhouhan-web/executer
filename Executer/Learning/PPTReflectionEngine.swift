import Foundation

/// Post-PPT-creation reflection engine.
/// Compares a generated .pptx against the user's trained reference style,
/// identifies design mismatches, and saves refinements for future use.
final class PPTReflectionEngine {
    static let shared = PPTReflectionEngine()

    /// Called after successful PPT creation. Runs asynchronously — does NOT block tool result.
    func reflect(generatedPath: String) async {
        print("[PPTReflection] Starting reflection on: \(generatedPath)")

        // 1. Extract design DNA from generated PPT
        guard let generatedDesign = await extractDesign(from: generatedPath) else {
            print("[PPTReflection] Failed to extract design from generated PPT")
            return
        }

        // 2. Load user's reference design_language.json
        guard let referenceDesign = loadReferenceDesign() else {
            print("[PPTReflection] No reference design language found — skipping reflection")
            return
        }

        // 3. Programmatic comparison
        let deltas = compare(reference: referenceDesign, generated: generatedDesign)
        print("[PPTReflection] Found \(deltas.count) design deltas (\(deltas.filter { $0.severity != .minor }.count) significant)")

        guard !deltas.isEmpty else {
            print("[PPTReflection] Generated PPT matches reference style — no refinements needed")
            return
        }

        // 4. Convert deltas to refinements
        var refinements = deltas.filter { $0.severity != .minor }.map { delta -> DesignRefinement in
            DesignRefinement(
                id: UUID(),
                createdAt: Date(),
                category: delta.category,
                observation: delta.observation,
                referenceValue: delta.referenceValue,
                generatedValue: delta.generatedValue,
                confidence: delta.severity == .major ? 0.6 : 0.3,
                occurrenceCount: 1
            )
        }

        // 5. Optional: ask LLM for additional refinement notes if many significant deltas
        let significantDeltas = deltas.filter { $0.severity != .minor }
        if significantDeltas.count >= 2 {
            let llmRefinements = await askLLMForRefinements(deltas: significantDeltas)
            refinements.append(contentsOf: llmRefinements)
        }

        // 6. Save to store
        DesignRefinementStore.shared.addAll(refinements)
        print("[PPTReflection] Saved \(refinements.count) design refinements")
    }

    // MARK: - Design Extraction

    private func extractDesign(from pptxPath: String) async -> [String: Any]? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let execDir = appSupport.appendingPathComponent("Executer")
        let extractorPath = execDir.appendingPathComponent("ppt_design_extractor.py")

        guard FileManager.default.fileExists(atPath: extractorPath.path) else { return nil }
        guard FileManager.default.fileExists(atPath: pptxPath) else { return nil }

        let tempOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("reflection_design_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempOutput) }

        let python = PPTExecutor.findPython()
        guard let result = try? await PPTExecutor.runPython(
            python: python,
            script: extractorPath.path,
            args: [pptxPath, "-o", tempOutput.path, "--format", "json"]
        ), result.exitCode == 0 else { return nil }

        guard let data = try? Data(contentsOf: tempOutput),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    // MARK: - Reference Loading

    private func loadReferenceDesign() -> [String: Any]? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let execDir = appSupport.appendingPathComponent("Executer")

        // Try per-file designs first (best quality trained profile)
        let trainedProfiles = DocumentStudyStore.shared.profiles
            .filter { $0.sourceFormat == "pptx" || $0.sourceFormat == "ppt" }
            .sorted { $0.qualityScore > $1.qualityScore }

        if let best = trainedProfiles.first {
            let safeName = URL(fileURLWithPath: best.sourceFile)
                .deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: " ", with: "_")
            let perFile = execDir.appendingPathComponent("design_language_\(safeName).json")
            if let data = try? Data(contentsOf: perFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }

        // Scan for any design_language_*.json
        if let contents = try? FileManager.default.contentsOfDirectory(at: execDir, includingPropertiesForKeys: [.contentModificationDateKey]),
           let newest = contents
            .filter({ $0.lastPathComponent.hasPrefix("design_language_") && $0.pathExtension == "json" })
            .sorted(by: {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return d1 > d2
            })
            .first {
            if let data = try? Data(contentsOf: newest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }

        // Global fallback
        let global = execDir.appendingPathComponent("design_language.json")
        if let data = try? Data(contentsOf: global),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        return nil
    }

    // MARK: - Comparison

    struct DesignDelta {
        let category: String
        let field: String
        let referenceValue: String
        let generatedValue: String
        let observation: String
        let severity: Severity

        enum Severity { case minor, significant, major }
    }

    private func compare(reference: [String: Any], generated: [String: Any]) -> [DesignDelta] {
        var deltas: [DesignDelta] = []

        let refDS = reference["design_system"] as? [String: Any] ?? [:]
        let genDS = generated["design_system"] as? [String: Any] ?? [:]

        // Compare semantic colors
        let refColors = refDS["semantic_colors"] as? [String: String] ?? [:]
        let genColors = genDS["semantic_colors"] as? [String: String] ?? [:]

        for key in ["accent", "text_primary", "text_secondary", "background"] {
            if let refHex = refColors[key], let genHex = genColors[key],
               refHex.lowercased() != genHex.lowercased() {
                let distance = colorDistance(refHex, genHex)
                let severity: DesignDelta.Severity = distance > 120 ? .major : distance > 60 ? .significant : .minor
                deltas.append(DesignDelta(
                    category: "color",
                    field: key,
                    referenceValue: refHex,
                    generatedValue: genHex,
                    observation: "User's \(key) color is \(refHex), not \(genHex)",
                    severity: severity
                ))
            }
        }

        // Compare primary font
        let refTypo = refDS["typography"] as? [String: Any] ?? [:]
        let genTypo = genDS["typography"] as? [String: Any] ?? [:]
        let refFonts = refTypo["fonts_by_frequency"] as? [[String: Any]] ?? []
        let genFonts = genTypo["fonts_by_frequency"] as? [[String: Any]] ?? []

        if let refFont = refFonts.first?["font"] as? String,
           let genFont = genFonts.first?["font"] as? String,
           refFont.lowercased() != genFont.lowercased() {
            deltas.append(DesignDelta(
                category: "font",
                field: "primary",
                referenceValue: refFont,
                generatedValue: genFont,
                observation: "User prefers \(refFont) font, not \(genFont)",
                severity: .major
            ))
        }

        // Compare text hierarchy (title/body sizes)
        let refHierarchy = refDS["text_hierarchy"] as? [[String: Any]] ?? []
        let genHierarchy = genDS["text_hierarchy"] as? [[String: Any]] ?? []

        for role in ["title", "body"] {
            if let refItem = refHierarchy.first(where: { ($0["likely_role"] as? String) == role }),
               let genItem = genHierarchy.first(where: { ($0["likely_role"] as? String) == role }),
               let refSize = refItem["size_pt"] as? Double,
               let genSize = genItem["size_pt"] as? Double,
               abs(refSize - genSize) > 4 {
                let severity: DesignDelta.Severity = abs(refSize - genSize) > 10 ? .significant : .minor
                deltas.append(DesignDelta(
                    category: "font",
                    field: "\(role)_size",
                    referenceValue: "\(Int(refSize))pt",
                    generatedValue: "\(Int(genSize))pt",
                    observation: "User's \(role) text is \(Int(refSize))pt, generated was \(Int(genSize))pt",
                    severity: severity
                ))
            }
        }

        // Compare design philosophy
        let refDP = reference["design_philosophy"] as? [String: Any] ?? [:]
        let genDP = generated["design_philosophy"] as? [String: Any] ?? [:]

        for key in ["content_density", "whitespace_style", "layout_complexity", "color_restraint"] {
            if let refVal = refDP[key] as? String,
               let genVal = genDP[key] as? String,
               refVal != genVal {
                deltas.append(DesignDelta(
                    category: "style",
                    field: key,
                    referenceValue: refVal,
                    generatedValue: genVal,
                    observation: "User's \(key.replacingOccurrences(of: "_", with: " ")) is '\(refVal)', generated was '\(genVal)'",
                    severity: .significant
                ))
            }
        }

        return deltas
    }

    /// Euclidean RGB color distance (0-441).
    private func colorDistance(_ hex1: String, _ hex2: String) -> Double {
        let c1 = parseHex(hex1)
        let c2 = parseHex(hex2)
        let dr = Double(c1.0 - c2.0)
        let dg = Double(c1.1 - c2.1)
        let db = Double(c1.2 - c2.2)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private func parseHex(_ hex: String) -> (Int, Int, Int) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let val = UInt32(h, radix: 16) else { return (0, 0, 0) }
        return (Int((val >> 16) & 0xFF), Int((val >> 8) & 0xFF), Int(val & 0xFF))
    }

    // MARK: - LLM Refinement (Optional)

    private func askLLMForRefinements(deltas: [DesignDelta]) async -> [DesignRefinement] {
        // Use Gemini Flash (same as trainer) for quick analysis
        let service: LLMServiceProtocol
        if APIKeyManager.shared.getKey(for: .gemini) != nil {
            service = OpenAICompatibleService(provider: .gemini, model: "gemini-2.5-flash")
        } else {
            return [] // Skip LLM refinement if no Gemini key
        }

        let deltaSummary = deltas.map { "- \($0.observation)" }.joined(separator: "\n")
        let prompt = """
            A PPT was just generated that differs from the user's preferred style. Here are the mismatches:

            \(deltaSummary)

            Write 3-5 SHORT, actionable design rules (one line each) that should be applied to ALL future presentations.
            Format each rule as: CATEGORY: rule text
            Categories: color, font, layout, spacing, style
            Example: color: Always use #2563EB as the primary accent color
            """

        let messages = [
            ChatMessage(role: "system", content: "You are a design consistency expert. Output only rules, no explanation."),
            ChatMessage(role: "user", content: prompt)
        ]

        guard let response = try? await service.sendChatRequest(messages: messages, tools: nil, maxTokens: 500),
              let text = response.text else { return [] }

        // Parse "CATEGORY: rule" lines
        return text.components(separatedBy: .newlines).compactMap { line -> DesignRefinement? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.components(separatedBy: ":")
            guard parts.count >= 2 else { return nil }
            let category = parts[0].lowercased().trimmingCharacters(in: .whitespaces)
            let rule = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            guard ["color", "font", "layout", "spacing", "style"].contains(category) else { return nil }
            return DesignRefinement(
                id: UUID(), createdAt: Date(),
                category: category, observation: rule,
                referenceValue: nil, generatedValue: nil,
                confidence: 0.25, occurrenceCount: 1
            )
        }
    }
}
