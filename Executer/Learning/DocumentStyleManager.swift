import Foundation

// MARK: - Style Profile Models

struct FontTheme: Codable {
    var headingFont: String?
    var bodyFont: String?
}

struct LayoutProfile: Codable {
    var name: String
    var placeholderCount: Int?
    var fonts: [String]?
}

struct HeadingStyle: Codable {
    var level: Int
    var font: String?
    var fontSize: Double?
    var bold: Bool?
    var color: String?  // hex
}

struct DocumentStyleProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    var sourceFiles: [String]
    var format: String  // "pptx" or "docx"
    var extractedAt: Date
    // PPTX
    var slideWidth: Double?
    var slideHeight: Double?
    var layouts: [LayoutProfile]?
    var colorScheme: [String: String]?
    var fontTheme: FontTheme?
    // DOCX
    var headingStyles: [HeadingStyle]?
    var bodyFont: String?
    var bodyFontSize: Double?
    var margins: [String: Double]?
}

// MARK: - Document Style Manager

/// Manages document style profiles — extracted from reference documents, applied to new creations.
final class DocumentStyleManager {
    static let shared = DocumentStyleManager()

    private let stylesDir: URL = {
        let appSupport = URL.applicationSupportDirectory
        let dir = appSupport.appendingPathComponent("Executer/document_styles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    // MARK: - CRUD

    func saveProfile(_ profile: DocumentStyleProfile) {
        let url = stylesDir.appendingPathComponent("\(profile.name).json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile)
            try data.write(to: url, options: .atomic)
            print("[DocumentStyle] Saved profile: \(profile.name)")
        } catch {
            print("[DocumentStyle] Failed to save profile: \(error)")
        }
    }

    func loadProfile(named name: String) -> DocumentStyleProfile? {
        let url = stylesDir.appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DocumentStyleProfile.self, from: data)
        } catch {
            print("[DocumentStyle] Failed to load profile '\(name)': \(error)")
            return nil
        }
    }

    func listProfiles() -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: stylesDir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func deleteProfile(named name: String) -> Bool {
        let url = stylesDir.appendingPathComponent("\(name).json")
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Prompt Section

    /// Brief summary of available styles for system prompt injection (500 chars max).
    func promptSection() -> String {
        let profiles = listProfiles()
        guard !profiles.isEmpty else { return "" }

        var lines = ["\n\n## Document Styles", "Saved style profiles you can apply when creating documents:"]
        for name in profiles {
            if let profile = loadProfile(named: name) {
                let fonts = [profile.fontTheme?.headingFont, profile.fontTheme?.bodyFont, profile.bodyFont]
                    .compactMap { $0 }
                    .joined(separator: ", ")
                lines.append("- **\(name)** (\(profile.format)) — fonts: \(fonts.isEmpty ? "default" : fonts)")
            }
        }
        lines.append("Use `extract_document_style` to learn from a reference document. Use `style_profile` parameter in `create_document` to apply.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Extract Document Style Tool

/// Extracts the visual style from a reference PPTX/DOCX and saves as a reusable profile.
struct ExtractDocumentStyleTool: ToolDefinition {
    let name = "extract_document_style"
    let description = "Analyze a PPTX/DOCX file and extract its complete visual style (fonts, colors, layouts, dimensions). Saves the style profile for reuse when creating new documents."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Path to the reference document (PPTX or DOCX)"),
            "profile_name": JSONSchema.string(description: "Name for the saved style profile (e.g., 'Allen Pitch Deck')"),
        ], required: ["path", "profile_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let profileName = try requiredString("profile_name", from: args)
        let path = NSString(string: rawPath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: path) else {
            return "File not found: \(path)"
        }

        let ext = (path as NSString).pathExtension.lowercased()

        switch ext {
        case "pptx", "ppt":
            return try await extractPptxStyle(path: path, profileName: profileName)
        case "docx", "doc":
            return try await extractDocxStyle(path: path, profileName: profileName)
        default:
            return "Unsupported format: .\(ext). Use a .pptx or .docx file."
        }
    }

    private func extractPptxStyle(path: String, profileName: String) async throws -> String {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        python3 -c "
        from pptx import Presentation
        from pptx.util import Emu
        import json

        p = Presentation('\(escapedPath)')
        result = {
            'slideWidth': round(p.slide_width / 914400, 2),
            'slideHeight': round(p.slide_height / 914400, 2),
            'layouts': [],
            'fonts': set(),
            'colorScheme': {},
            'fontTheme': {}
        }

        # Extract layouts
        for layout in p.slide_layouts:
            l = {'name': layout.name, 'placeholderCount': len(layout.placeholders), 'fonts': []}
            for ph in layout.placeholders:
                if ph.has_text_frame:
                    for para in ph.text_frame.paragraphs:
                        for run in para.runs:
                            if run.font.name:
                                l['fonts'].append(run.font.name)
                                result['fonts'].add(run.font.name)
            result['layouts'].append(l)

        # Extract fonts from actual slides
        heading_font = None
        body_font = None
        for slide in p.slides:
            for shape in slide.shapes:
                if shape.has_text_frame:
                    for para in shape.text_frame.paragraphs:
                        for run in para.runs:
                            if run.font.name:
                                result['fonts'].add(run.font.name)
                                if run.font.bold and not heading_font:
                                    heading_font = run.font.name
                                elif not body_font:
                                    body_font = run.font.name

        # Try to get theme colors
        try:
            theme = p.slide_masters[0].slide_layouts[0].slide_master.element
            import lxml.etree as ET
            ns = {'a': 'http://schemas.openxmlformats.org/drawingml/2006/main'}
            for elem in theme.iter():
                tag = elem.tag.split('}')[-1] if '}' in elem.tag else elem.tag
                if tag in ['dk1', 'dk2', 'lt1', 'lt2', 'accent1', 'accent2', 'accent3', 'accent4', 'accent5', 'accent6']:
                    for child in elem:
                        if 'val' in child.attrib:
                            result['colorScheme'][tag] = child.attrib['val']
                        elif 'lastClr' in child.attrib:
                            result['colorScheme'][tag] = child.attrib['lastClr']
        except:
            pass

        result['fontTheme'] = {'headingFont': heading_font, 'bodyFont': body_font}
        result['fonts'] = list(result['fonts'])
        print(json.dumps(result, indent=2))
        "
        """

        let result = try ShellRunner.run(script, timeout: 30)
        if result.exitCode != 0 {
            if result.output.contains("ModuleNotFoundError") {
                return "python-pptx not installed. Auto-provisioning failed — check python venv."
            }
            return "Failed to extract style: \(result.output)"
        }

        // Parse the JSON result
        guard let data = result.output.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Failed to parse extraction result."
        }

        var fontTheme = FontTheme()
        if let ft = dict["fontTheme"] as? [String: Any] {
            fontTheme.headingFont = ft["headingFont"] as? String
            fontTheme.bodyFont = ft["bodyFont"] as? String
        }

        var layouts: [LayoutProfile] = []
        if let layoutList = dict["layouts"] as? [[String: Any]] {
            for l in layoutList {
                layouts.append(LayoutProfile(
                    name: l["name"] as? String ?? "Unknown",
                    placeholderCount: l["placeholderCount"] as? Int,
                    fonts: l["fonts"] as? [String]
                ))
            }
        }

        let profile = DocumentStyleProfile(
            id: UUID(),
            name: profileName,
            sourceFiles: [path],
            format: "pptx",
            extractedAt: Date(),
            slideWidth: dict["slideWidth"] as? Double,
            slideHeight: dict["slideHeight"] as? Double,
            layouts: layouts,
            colorScheme: dict["colorScheme"] as? [String: String],
            fontTheme: fontTheme,
            headingStyles: nil,
            bodyFont: nil,
            bodyFontSize: nil,
            margins: nil
        )

        DocumentStyleManager.shared.saveProfile(profile)

        let fonts = (dict["fonts"] as? [String]) ?? []
        return """
        Style profile '\(profileName)' extracted and saved.
        - Slide dimensions: \(profile.slideWidth ?? 0)" x \(profile.slideHeight ?? 0)"
        - Layouts: \(layouts.count) (\(layouts.prefix(5).map(\.name).joined(separator: ", ")))
        - Heading font: \(fontTheme.headingFont ?? "default")
        - Body font: \(fontTheme.bodyFont ?? "default")
        - All fonts found: \(fonts.joined(separator: ", "))
        - Color scheme entries: \(profile.colorScheme?.count ?? 0)
        """
    }

    private func extractDocxStyle(path: String, profileName: String) async throws -> String {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        python3 -c "
        from docx import Document
        from docx.shared import Pt, Inches
        import json

        doc = Document('\(escapedPath)')
        result = {'headingStyles': [], 'bodyFont': None, 'bodyFontSize': None, 'margins': {}}

        # Extract margins
        for section in doc.sections:
            result['margins'] = {
                'top': round(section.top_margin / 914400, 2) if section.top_margin else 1.0,
                'bottom': round(section.bottom_margin / 914400, 2) if section.bottom_margin else 1.0,
                'left': round(section.left_margin / 914400, 2) if section.left_margin else 1.25,
                'right': round(section.right_margin / 914400, 2) if section.right_margin else 1.25,
            }
            break

        # Extract heading and body styles
        seen_levels = set()
        for para in doc.paragraphs:
            if para.style and para.style.name and para.style.name.startswith('Heading'):
                try:
                    level = int(para.style.name.replace('Heading ', '').replace('Heading', '1'))
                except:
                    level = 1
                if level not in seen_levels and para.runs:
                    r = para.runs[0]
                    hs = {'level': level}
                    if r.font.name: hs['font'] = r.font.name
                    if r.font.size: hs['fontSize'] = round(r.font.size.pt, 1)
                    if r.font.bold is not None: hs['bold'] = r.font.bold
                    result['headingStyles'].append(hs)
                    seen_levels.add(level)
            elif para.style and 'Normal' in (para.style.name or '') and para.runs:
                r = para.runs[0]
                if r.font.name and not result['bodyFont']:
                    result['bodyFont'] = r.font.name
                if r.font.size and not result['bodyFontSize']:
                    result['bodyFontSize'] = round(r.font.size.pt, 1)

        print(json.dumps(result, indent=2))
        "
        """

        let docResult = try ShellRunner.run(script, timeout: 30)
        if docResult.exitCode != 0 {
            if docResult.output.contains("ModuleNotFoundError") {
                return "python-docx not installed. Auto-provisioning failed — check python venv."
            }
            return "Failed to extract style: \(docResult.output)"
        }

        guard let data = docResult.output.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Failed to parse extraction result."
        }

        var headingStyles: [HeadingStyle] = []
        if let hsList = dict["headingStyles"] as? [[String: Any]] {
            for hs in hsList {
                headingStyles.append(HeadingStyle(
                    level: hs["level"] as? Int ?? 1,
                    font: hs["font"] as? String,
                    fontSize: hs["fontSize"] as? Double,
                    bold: hs["bold"] as? Bool,
                    color: hs["color"] as? String
                ))
            }
        }

        let profile = DocumentStyleProfile(
            id: UUID(),
            name: profileName,
            sourceFiles: [path],
            format: "docx",
            extractedAt: Date(),
            slideWidth: nil,
            slideHeight: nil,
            layouts: nil,
            colorScheme: nil,
            fontTheme: nil,
            headingStyles: headingStyles,
            bodyFont: dict["bodyFont"] as? String,
            bodyFontSize: dict["bodyFontSize"] as? Double,
            margins: dict["margins"] as? [String: Double]
        )

        DocumentStyleManager.shared.saveProfile(profile)

        return """
        Style profile '\(profileName)' extracted and saved.
        - Body font: \(profile.bodyFont ?? "default") \(profile.bodyFontSize.map { "\($0)pt" } ?? "")
        - Heading styles: \(headingStyles.count) levels
        - Margins: \(profile.margins?.map { "\($0.key): \($0.value)\"" }.joined(separator: ", ") ?? "default")
        """
    }
}

// MARK: - List Document Styles Tool

struct ListDocumentStylesTool: ToolDefinition {
    let name = "list_document_styles"
    let description = "List all saved document style profiles available for use with create_document."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let profiles = DocumentStyleManager.shared.listProfiles()
        guard !profiles.isEmpty else {
            return "No style profiles saved yet. Use extract_document_style to learn a style from a reference document."
        }

        var result = "**Saved Document Styles:**\n"
        for name in profiles {
            if let profile = DocumentStyleManager.shared.loadProfile(named: name) {
                result += "\n- **\(name)** (\(profile.format.uppercased()))"
                result += "\n  Source: \(profile.sourceFiles.first.map { ($0 as NSString).lastPathComponent } ?? "unknown")"
                if let ft = profile.fontTheme {
                    result += "\n  Fonts: heading=\(ft.headingFont ?? "default"), body=\(ft.bodyFont ?? "default")"
                }
                if let bf = profile.bodyFont {
                    result += "\n  Body: \(bf) \(profile.bodyFontSize.map { "\($0)pt" } ?? "")"
                }
            }
        }
        return result
    }
}
