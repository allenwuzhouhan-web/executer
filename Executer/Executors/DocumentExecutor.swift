import Foundation

// MARK: - Read Document

/// Reads binary documents (PPTX, DOCX, XLSX) by extracting text + structure.
/// Solves the "Cannot read binary file" error for office documents.
struct ReadDocumentTool: ToolDefinition {
    let name = "read_document"
    let description = "Read content from binary documents (PPTX, DOCX, XLSX). Extracts text, structure, and metadata. Use this instead of read_file for Office documents."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the document (use ~ for home directory)"),
            "format": JSONSchema.enumString(description: "Output format: 'text' (plain text), 'json' (structured), 'structure' (full with layout info)", values: ["text", "json", "structure"]),
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let format = optionalString("format", from: args) ?? "text"

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        guard FileManager.default.fileExists(atPath: path) else {
            return "File not found: \(path)"
        }

        let ext = (path as NSString).pathExtension.lowercased()

        switch ext {
        case "docx", "doc":
            return try readDocx(path: path, format: format)
        case "pptx", "ppt":
            return try await readPptx(path: path, format: format)
        case "xlsx", "xls":
            return try await readXlsx(path: path, format: format)
        default:
            return "Unsupported document format: .\(ext). Supported: docx, pptx, xlsx."
        }
    }

    // MARK: - DOCX (native macOS textutil)

    private func readDocx(path: String, format: String) throws -> String {
        let result = try ShellRunner.run("textutil -convert txt -stdout \"\(path)\"", timeout: 15)
        if result.exitCode != 0 {
            return "Failed to read DOCX: \(result.output)"
        }

        if format == "text" {
            return result.output.isEmpty ? "Document is empty or could not be read." : result.output
        }

        // For json/structure, add metadata
        let fileInfo = try ShellRunner.run("mdls -name kMDItemNumberOfPages -name kMDItemAuthors -name kMDItemTitle \"\(path)\"", timeout: 5)
        return """
        **Document:** \((path as NSString).lastPathComponent)
        **Metadata:**
        \(fileInfo.output)

        **Content:**
        \(result.output)
        """
    }

    // MARK: - PPTX (Python python-pptx)

    private func readPptx(path: String, format: String) async throws -> String {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")

        let script: String
        if format == "structure" {
            script = """
            python3 -c "
            from pptx import Presentation
            from pptx.util import Inches, Pt, Emu
            import json
            p = Presentation('\(escapedPath)')
            w = p.slide_width
            h = p.slide_height
            result = {'slide_width_inches': round(w/914400, 2), 'slide_height_inches': round(h/914400, 2), 'slide_count': len(p.slides), 'slides': []}
            for i, slide in enumerate(p.slides):
                s = {'index': i+1, 'layout': slide.slide_layout.name if slide.slide_layout else 'Unknown', 'shapes': []}
                for shape in slide.shapes:
                    sh = {'name': shape.name, 'type': shape.shape_type.__class__.__name__ if hasattr(shape.shape_type, '__class__') else str(shape.shape_type)}
                    if shape.has_text_frame:
                        texts = []
                        for para in shape.text_frame.paragraphs:
                            t = para.text.strip()
                            if t:
                                font_info = {}
                                if para.runs:
                                    r = para.runs[0]
                                    if r.font.name: font_info['font'] = r.font.name
                                    if r.font.size: font_info['size_pt'] = round(r.font.size.pt, 1)
                                    if r.font.bold: font_info['bold'] = True
                                texts.append({'text': t, **font_info})
                        sh['content'] = texts
                    s['shapes'].append(sh)
                result['slides'].append(s)
            print(json.dumps(result, indent=2))
            "
            """
        } else {
            script = """
            python3 -c "
            from pptx import Presentation
            p = Presentation('\(escapedPath)')
            for i, slide in enumerate(p.slides):
                print(f'--- Slide {i+1} ({slide.slide_layout.name if slide.slide_layout else \"Unknown\"}) ---')
                for shape in slide.shapes:
                    if shape.has_text_frame:
                        for para in shape.text_frame.paragraphs:
                            t = para.text.strip()
                            if t: print(t)
                print()
            "
            """
        }

        let result = try ShellRunner.run(script, timeout: 30)

        if result.exitCode != 0 {
            if result.output.contains("ModuleNotFoundError") || result.output.contains("No module named") {
                return "python-pptx not installed. Call setup_python_docs first, then retry."
            }
            // Try Spotlight fallback
            let fallback = try ShellRunner.run("mdimport -d2 \"\(path)\" 2>&1 | head -50", timeout: 10)
            return fallback.output.isEmpty ? "Failed to read PPTX: \(result.output)" : fallback.output
        }

        return result.output.isEmpty ? "Presentation is empty." : result.output
    }

    // MARK: - XLSX (Python openpyxl)

    private func readXlsx(path: String, format: String) async throws -> String {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")

        let script: String
        if format == "structure" {
            script = """
            python3 -c "
            import openpyxl, json
            wb = openpyxl.load_workbook('\(escapedPath)', read_only=True, data_only=True)
            result = {'sheets': []}
            for name in wb.sheetnames:
                ws = wb[name]
                rows = []
                for row in ws.iter_rows(max_row=min(ws.max_row or 0, 100), values_only=True):
                    rows.append([str(c) if c is not None else '' for c in row])
                result['sheets'].append({'name': name, 'rows': len(rows), 'columns': ws.max_column or 0, 'data': rows[:20]})
            wb.close()
            print(json.dumps(result, indent=2))
            "
            """
        } else {
            script = """
            python3 -c "
            import openpyxl
            wb = openpyxl.load_workbook('\(escapedPath)', read_only=True, data_only=True)
            for name in wb.sheetnames:
                print(f'--- Sheet: {name} ---')
                ws = wb[name]
                for i, row in enumerate(ws.iter_rows(max_row=min(ws.max_row or 0, 50), values_only=True)):
                    vals = [str(c) if c is not None else '' for c in row]
                    print('\\t'.join(vals))
                    if i >= 49: print('... (truncated)')
                print()
            wb.close()
            "
            """
        }

        let result = try ShellRunner.run(script, timeout: 30)

        if result.exitCode != 0 {
            if result.output.contains("ModuleNotFoundError") || result.output.contains("No module named") {
                return "openpyxl not installed. Call setup_python_docs first, then retry."
            }
            return "Failed to read XLSX: \(result.output)"
        }

        return result.output.isEmpty ? "Spreadsheet is empty." : result.output
    }
}

// MARK: - Create Document

/// Creates binary documents (PPTX, DOCX, XLSX) via dynamically generated Python scripts.
struct CreateDocumentTool: ToolDefinition {
    let name = "create_document"
    let description = "Create a PowerPoint, Word, or Excel document. Generates the file using Python libraries."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Output file path (use ~ for home directory). Extension determines format."),
            "format": JSONSchema.enumString(description: "Document format", values: ["pptx", "docx", "xlsx"]),
            "content": JSONSchema.string(description: "JSON string describing document content. PPTX: {\"slides\":[{\"title\":\"...\",\"body\":\"...\",\"bullets\":[\"...\"],\"layout\":\"Title Slide\"}]}. DOCX: {\"sections\":[{\"heading\":\"...\",\"level\":1,\"body\":\"...\",\"bullets\":[\"...\"]}]}. XLSX: {\"sheets\":[{\"name\":\"...\",\"data\":[[\"A1\",\"B1\"],[\"A2\",\"B2\"]]}]}"),
            "style_profile": JSONSchema.string(description: "Name of a saved document style profile to apply (optional). Use list_document_styles to see available styles."),
        ], required: ["path", "format", "content"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let format = try requiredString("format", from: args)
        let contentJSON = try requiredString("content", from: args)
        let styleProfile = optionalString("style_profile", from: args)

        let path = NSString(string: rawPath).expandingTildeInPath
        try PathSecurity.validate(path)

        // Ensure parent directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Load style profile if specified
        var styleJSON: String? = nil
        if let profileName = styleProfile {
            if let profile = DocumentStyleManager.shared.loadProfile(named: profileName) {
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(profile) {
                    styleJSON = String(data: data, encoding: .utf8)
                }
            }
        }

        let script: String
        switch format {
        case "pptx":
            script = generatePptxScript(path: path, contentJSON: contentJSON, styleJSON: styleJSON)
        case "docx":
            script = generateDocxScript(path: path, contentJSON: contentJSON, styleJSON: styleJSON)
        case "xlsx":
            script = generateXlsxScript(path: path, contentJSON: contentJSON)
        default:
            return "Unsupported format: \(format). Use pptx, docx, or xlsx."
        }

        // Write script to temp file and execute
        let tempScript = NSTemporaryDirectory() + "executer_doc_\(UUID().uuidString.prefix(8)).py"
        try script.write(toFile: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempScript) }

        let result = try ShellRunner.run("python3 \"\(tempScript)\"", timeout: 60)

        if result.exitCode != 0 {
            if result.output.contains("ModuleNotFoundError") || result.output.contains("No module named") {
                return "Required Python library not installed. Call setup_python_docs first, then retry."
            }
            return "Failed to create document: \(result.output)"
        }

        // Verify file was created
        if FileManager.default.fileExists(atPath: path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = attrs?[.size] as? UInt64 ?? 0
            return "Created \(format.uppercased()) at \(path) (\(size / 1024)KB)"
        } else {
            return "Script ran but file was not created at \(path). Output: \(result.output)"
        }
    }

    // MARK: - Python Script Generators

    private func generatePptxScript(path: String, contentJSON: String, styleJSON: String?) -> String {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedContent = contentJSON.replacingOccurrences(of: "'", with: "'\\''")
        let styleSection: String
        if let sj = styleJSON {
            let escapedStyle = sj.replacingOccurrences(of: "'", with: "'\\''")
            styleSection = """
            style = json.loads('''\(escapedStyle)''')
            """
        } else {
            styleSection = "style = None"
        }

        return """
        import json
        from pptx import Presentation
        from pptx.util import Inches, Pt, Emu
        from pptx.enum.text import PP_ALIGN
        from pptx.dml.color import RGBColor

        content = json.loads('''\(escapedContent)''')
        \(styleSection)

        prs = Presentation()

        # Apply style if available
        if style:
            if 'slideWidth' in style and style['slideWidth']:
                prs.slide_width = Emu(int(style['slideWidth'] * 914400))
            if 'slideHeight' in style and style['slideHeight']:
                prs.slide_height = Emu(int(style['slideHeight'] * 914400))

        layout_map = {}
        for layout in prs.slide_layouts:
            layout_map[layout.name.lower()] = layout

        def get_layout(name):
            lower = name.lower() if name else 'title and content'
            for key in layout_map:
                if lower in key or key in lower:
                    return layout_map[key]
            # Fallback: 0 = Title, 1 = Title+Content, 5 = Blank
            if 'title' in lower and ('slide' in lower or 'only' in lower):
                return prs.slide_layouts[0]
            elif 'blank' in lower:
                return prs.slide_layouts[min(5, len(prs.slide_layouts)-1)]
            return prs.slide_layouts[min(1, len(prs.slide_layouts)-1)]

        def apply_font_style(run, style):
            if not style:
                return
            font_theme = style.get('fontTheme', {})
            if font_theme.get('bodyFont'):
                run.font.name = font_theme['bodyFont']
            color_scheme = style.get('colorScheme', {})
            if color_scheme.get('text1'):
                c = color_scheme['text1'].lstrip('#')
                if len(c) == 6:
                    run.font.color.rgb = RGBColor(int(c[:2],16), int(c[2:4],16), int(c[4:6],16))

        for slide_data in content.get('slides', []):
            layout_name = slide_data.get('layout', 'Title and Content')
            layout = get_layout(layout_name)
            slide = prs.slides.add_slide(layout)

            # Title
            if slide.shapes.title and slide_data.get('title'):
                slide.shapes.title.text = slide_data['title']
                if style:
                    font_theme = style.get('fontTheme', {})
                    for para in slide.shapes.title.text_frame.paragraphs:
                        for run in para.runs:
                            if font_theme.get('headingFont'):
                                run.font.name = font_theme['headingFont']
                            run.font.bold = True

            # Body text
            body_placeholder = None
            for shape in slide.placeholders:
                if shape.placeholder_format.idx == 1:
                    body_placeholder = shape
                    break

            if body_placeholder and body_placeholder.has_text_frame:
                tf = body_placeholder.text_frame
                tf.clear()

                if slide_data.get('bullets'):
                    for i, bullet in enumerate(slide_data['bullets']):
                        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
                        p.text = bullet
                        p.level = 0
                        for run in p.runs:
                            apply_font_style(run, style)

                elif slide_data.get('body'):
                    tf.paragraphs[0].text = slide_data['body']
                    for run in tf.paragraphs[0].runs:
                        apply_font_style(run, style)

        prs.save('\(escapedPath)')
        print('OK')
        """
    }

    private func generateDocxScript(path: String, contentJSON: String, styleJSON: String?) -> String {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedContent = contentJSON.replacingOccurrences(of: "'", with: "'\\''")
        let styleSection: String
        if let sj = styleJSON {
            let escapedStyle = sj.replacingOccurrences(of: "'", with: "'\\''")
            styleSection = """
            style = json.loads('''\(escapedStyle)''')
            """
        } else {
            styleSection = "style = None"
        }

        return """
        import json
        from docx import Document
        from docx.shared import Pt, Inches, RGBColor
        from docx.enum.text import WD_ALIGN_PARAGRAPH

        content = json.loads('''\(escapedContent)''')
        \(styleSection)

        doc = Document()

        # Apply style margins if available
        if style and style.get('margins'):
            for section in doc.sections:
                m = style['margins']
                if 'top' in m: section.top_margin = Inches(m['top'])
                if 'bottom' in m: section.bottom_margin = Inches(m['bottom'])
                if 'left' in m: section.left_margin = Inches(m['left'])
                if 'right' in m: section.right_margin = Inches(m['right'])

        def apply_body_style(run):
            if not style:
                return
            if style.get('bodyFont'):
                run.font.name = style['bodyFont']
            if style.get('bodyFontSize'):
                run.font.size = Pt(style['bodyFontSize'])

        for section in content.get('sections', []):
            level = section.get('level', 1)
            if section.get('heading'):
                h = doc.add_heading(section['heading'], level=min(level, 9))
                if style:
                    font_theme = style.get('fontTheme', {})
                    if font_theme and font_theme.get('headingFont'):
                        for run in h.runs:
                            run.font.name = font_theme['headingFont']

            if section.get('body'):
                p = doc.add_paragraph(section['body'])
                for run in p.runs:
                    apply_body_style(run)

            if section.get('bullets'):
                for bullet in section['bullets']:
                    p = doc.add_paragraph(bullet, style='List Bullet')
                    for run in p.runs:
                        apply_body_style(run)

        doc.save('\(escapedPath)')
        print('OK')
        """
    }

    private func generateXlsxScript(path: String, contentJSON: String) -> String {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedContent = contentJSON.replacingOccurrences(of: "'", with: "'\\''")

        return """
        import json
        import openpyxl
        from openpyxl.styles import Font, Alignment

        content = json.loads('''\(escapedContent)''')
        wb = openpyxl.Workbook()

        # Remove default sheet if we have named sheets
        if content.get('sheets'):
            default_sheet = wb.active
            for i, sheet_data in enumerate(content['sheets']):
                if i == 0:
                    ws = default_sheet
                    ws.title = sheet_data.get('name', 'Sheet1')
                else:
                    ws = wb.create_sheet(title=sheet_data.get('name', f'Sheet{i+1}'))

                for row_idx, row in enumerate(sheet_data.get('data', []), 1):
                    for col_idx, value in enumerate(row, 1):
                        cell = ws.cell(row=row_idx, column=col_idx, value=value)
                        # Bold header row
                        if row_idx == 1:
                            cell.font = Font(bold=True)

        wb.save('\(escapedPath)')
        print('OK')
        """
    }
}

// MARK: - Setup Python Docs

/// Installs required Python libraries for document operations.
struct SetupPythonDocsTool: ToolDefinition {
    let name = "setup_python_docs"
    let description = "Install Python libraries needed for document operations (python-pptx, python-docx, openpyxl). Run this once before using read_document or create_document."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        // Check if already installed
        let check = try ShellRunner.run("python3 -c \"import pptx; import docx; import openpyxl; print('OK')\"", timeout: 10)
        if check.exitCode == 0 && check.output.contains("OK") {
            return "All document libraries already installed (python-pptx, python-docx, openpyxl)."
        }

        // Install missing libraries
        let install = try ShellRunner.run("pip3 install python-pptx python-docx openpyxl --quiet 2>&1", timeout: 120)
        if install.exitCode != 0 {
            return "Failed to install libraries: \(install.output)\n\nTry running manually: pip3 install python-pptx python-docx openpyxl"
        }

        // Verify
        let verify = try ShellRunner.run("python3 -c \"import pptx; import docx; import openpyxl; print('OK')\"", timeout: 10)
        if verify.exitCode == 0 && verify.output.contains("OK") {
            return "Successfully installed: python-pptx, python-docx, openpyxl. Document tools are now ready."
        }

        return "Installation may have partially succeeded. Output: \(install.output)"
    }
}
