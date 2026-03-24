import Foundation
import Vision
import Cocoa

struct CaptureScreenTool: ToolDefinition {
    let name = "capture_screen"
    let description = "Take a screenshot and save it to the Desktop"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "filename": JSONSchema.string(description: "Optional filename (without extension). Defaults to 'screenshot'.")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let filename = optionalString("filename", from: args) ?? "screenshot-\(Int(Date().timeIntervalSince1970))"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let path = desktop.appendingPathComponent("\(filename).png").path
        let result = try ShellRunner.run("screencapture -x \"\(path)\"")
        if result.exitCode == 0 {
            return "Screenshot saved to Desktop: \(filename).png"
        }
        return "Failed to capture screenshot."
    }
}

struct CaptureWindowTool: ToolDefinition {
    let name = "capture_window"
    let description = "Take a screenshot of the frontmost window"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "filename": JSONSchema.string(description: "Optional filename (without extension)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let filename = optionalString("filename", from: args) ?? "window-\(Int(Date().timeIntervalSince1970))"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let path = desktop.appendingPathComponent("\(filename).png").path
        let result = try ShellRunner.run("screencapture -x -w \"\(path)\"")
        if result.exitCode == 0 {
            return "Window screenshot saved: \(filename).png"
        }
        return "Failed to capture window."
    }
}

// MARK: - Step 4: Enhanced Screenshot Tools

struct CaptureScreenToClipboardTool: ToolDefinition {
    let name = "capture_screen_to_clipboard"
    let description = "Take a screenshot and copy it to the clipboard (no file saved)"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let result = try ShellRunner.run("screencapture -c -x")
        if result.exitCode == 0 {
            return "Screenshot copied to clipboard."
        }
        return "Failed to capture screenshot to clipboard."
    }
}

struct CaptureAreaTool: ToolDefinition {
    let name = "capture_area"
    let description = "Take a screenshot of a user-selected area (interactive region selection)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "filename": JSONSchema.string(description: "Optional filename (without extension)")
        ])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let filename = optionalString("filename", from: args) ?? "area-\(Int(Date().timeIntervalSince1970))"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let path = desktop.appendingPathComponent("\(filename).png").path
        let result = try ShellRunner.run("screencapture -i -x \"\(path)\"")
        if result.exitCode == 0 && FileManager.default.fileExists(atPath: path) {
            return "Area screenshot saved to Desktop: \(filename).png"
        }
        return "Screenshot cancelled or failed."
    }
}

struct OCRImageTool: ToolDefinition {
    let name = "ocr_image"
    let description = "Extract text from an image file using Apple Vision OCR"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Path to the image file")
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let path = try requiredString("path", from: args)
        let expandedPath = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw ExecuterError.invalidArguments("File not found: \(path)")
        }

        guard let image = NSImage(contentsOf: url),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            throw ExecuterError.invalidArguments("Could not load image: \(path)")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else {
            return "No text found in image."
        }

        let text = observations.compactMap { observation -> String? in
            observation.topCandidates(1).first?.string
        }.joined(separator: "\n")

        if text.isEmpty {
            return "No text found in image."
        }

        return "Extracted text from \(url.lastPathComponent):\n\(text)"
    }
}

