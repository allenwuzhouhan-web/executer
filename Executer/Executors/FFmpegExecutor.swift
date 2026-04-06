import AppKit
import Foundation

// MARK: - FFmpeg Executor Helpers

enum FFmpegExecutor {
    struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Cached FFmpeg path — detected once, reused.
    private static var cachedFFmpegPath: String?

    /// Cached FFprobe path — detected once, reused.
    private static var cachedFFprobePath: String?

    /// Find FFmpeg executable. Returns nil if not installed.
    static func findFFmpeg() -> String? {
        if let cached = cachedFFmpegPath { return cached }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedFFmpegPath = path
                return path
            }
        }

        // Try `which ffmpeg`
        let whichProcess = Process()
        let pipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["ffmpeg"]
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        try? whichProcess.run()
        whichProcess.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty && FileManager.default.isExecutableFile(atPath: output) {
            cachedFFmpegPath = output
            return output
        }

        return nil
    }

    /// Find FFprobe executable. Returns nil if not installed.
    static func findFFprobe() -> String? {
        if let cached = cachedFFprobePath { return cached }

        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedFFprobePath = path
                return path
            }
        }

        // Try `which ffprobe`
        let whichProcess = Process()
        let pipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["ffprobe"]
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        try? whichProcess.run()
        whichProcess.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty && FileManager.default.isExecutableFile(atPath: output) {
            cachedFFprobePath = output
            return output
        }

        return nil
    }

    /// Copy a resource from the app bundle to the Executer App Support directory.
    static func ensureResource(_ name: String, ext: String, in dir: URL) {
        let dest = dir.appendingPathComponent("\(name).\(ext)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let bundled = Bundle.main.url(forResource: name, withExtension: ext) {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: bundled, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }

    /// Run a Python engine script with FFmpeg paths injected.
    /// CRITICAL: Reads pipes BEFORE waitUntilExit to avoid deadlock on large output.
    static func runEngine(spec: String, engine: String, outputPath: String,
                          mode: String, extraArgs: [String] = [],
                          timeoutSeconds: Int = 300) async throws -> ProcessResult {
        guard let ffmpeg = findFFmpeg() else {
            return ProcessResult(stdout: "{\"success\": false, \"error\": \"FFmpeg not found. Run setup_ffmpeg first.\"}", stderr: "", exitCode: 1)
        }

        let python = PPTExecutor.findPython()

        let appSupport = URL.applicationSupportDirectory
        let execDir = appSupport.appendingPathComponent("Executer")

        ensureResource(engine, ext: "py", in: execDir)
        ensureResource("image_utils", ext: "py", in: execDir)

        let enginePath = execDir.appendingPathComponent("\(engine).py")
        guard FileManager.default.fileExists(atPath: enginePath.path) else {
            return ProcessResult(stdout: "{\"success\": false, \"error\": \"\(engine).py not found. Reinstall the app.\"}", stderr: "", exitCode: 1)
        }

        // Write spec to temp file
        let tempSpec = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg_spec_\(UUID().uuidString).json")
        try spec.write(to: tempSpec, atomically: true, encoding: .utf8)

        var args = [
            enginePath.path,
            "--spec", tempSpec.path,
            "--output", outputPath,
            "--ffmpeg", ffmpeg,
            "--mode", mode,
        ]
        if let ffprobe = findFFprobe() {
            args += ["--ffprobe", ffprobe]
        }
        args += extraArgs

        defer { try? FileManager.default.removeItem(at: tempSpec) }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = args
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = ProcessInfo.processInfo.environment.merging([
                    "PYTHONIOENCODING": "utf-8",
                    "PYTHONUNBUFFERED": "1",
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
                ]) { _, new in new }

                do {
                    try process.run()

                    // Timeout
                    let pid = process.processIdentifier
                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(deadline: .now() + .seconds(timeoutSeconds))
                    timer.setEventHandler {
                        if process.isRunning {
                            kill(pid, SIGTERM)
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                                if process.isRunning { kill(pid, SIGKILL) }
                            }
                        }
                    }
                    timer.resume()

                    // Read pipes BEFORE waitUntilExit to avoid deadlock when output exceeds ~64KB
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timer.cancel()

                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus == SIGTERM || process.terminationStatus == SIGKILL {
                        continuation.resume(returning: ProcessResult(
                            stdout: "{\"success\": false, \"error\": \"FFmpeg engine timed out after \(timeoutSeconds) seconds.\"}",
                            stderr: err, exitCode: process.terminationStatus
                        ))
                        return
                    }

                    continuation.resume(returning: ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run ffprobe directly (no Python needed).
    static func probe(path: String) async throws -> ProcessResult {
        guard let ffprobe = findFFprobe() else {
            return ProcessResult(stdout: "", stderr: "FFprobe not found. Run setup_ffmpeg first.", exitCode: 1)
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: ffprobe)
                process.arguments = ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", path]
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
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

// MARK: - Setup FFmpeg Tool

struct SetupFFmpegTool: ToolDefinition {
    let name = "setup_ffmpeg"
    let description = "Check if FFmpeg is installed and report its version. Attempts to install via Homebrew if missing."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        // Check FFmpeg
        if let ffmpeg = FFmpegExecutor.findFFmpeg() {
            let result = try await FFmpegExecutor.probe(path: "")  // dummy call to test, we'll get version differently
            // Get version
            let versionResult = try await getVersion(executable: ffmpeg)
            var report = "FFmpeg installed: \(ffmpeg)\nVersion: \(versionResult)"

            if let ffprobe = FFmpegExecutor.findFFprobe() {
                report += "\nFFprobe installed: \(ffprobe)"
            } else {
                report += "\nFFprobe: NOT FOUND (some features may be limited)"
            }

            // Check yt-dlp for YouTube style learning
            let ytdlp = findExecutable("yt-dlp")
            if let yt = ytdlp {
                report += "\nyt-dlp installed: \(yt)"
            } else {
                report += "\nyt-dlp: not installed (optional — needed for analyze_youtube_channel)"
            }

            return report
        }

        // Try to install via Homebrew
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for brewPath in brewPaths {
            if FileManager.default.isExecutableFile(atPath: brewPath) {
                let process = Process()
                let pipe = Pipe()
                let errPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: brewPath)
                process.arguments = ["install", "ffmpeg"]
                process.standardOutput = pipe
                process.standardError = errPipe
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    // Clear cache so next find picks it up
                    return "FFmpeg installed successfully via Homebrew. Ready to use."
                } else {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    return "Failed to install FFmpeg via Homebrew: \(err.prefix(300))\nPlease install manually: brew install ffmpeg"
                }
            }
        }

        return "FFmpeg not found and Homebrew not available. Please install FFmpeg:\n• brew install ffmpeg\n• Or download from https://ffmpeg.org/download.html"
    }

    private func getVersion(executable: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["-version"]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let firstLine = output.components(separatedBy: "\n").first ?? output
                    continuation.resume(returning: firstLine)
                } catch {
                    continuation.resume(returning: "unknown")
                }
            }
        }
    }

    private func findExecutable(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

// MARK: - FFmpeg Probe Tool

struct FFmpegProbeTool: ToolDefinition {
    let name = "ffmpeg_probe"
    let description = "Inspect a media file (video, audio, image) and return detailed metadata: duration, resolution, codecs, bitrate, audio channels, etc."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute path to the media file to inspect."),
        ], required: ["path"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let filePath = try requiredString("path", from: args)
        let expanded = NSString(string: filePath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expanded) else {
            return "Error: File not found at \(expanded)"
        }

        let result = try await FFmpegExecutor.probe(path: expanded)

        if result.exitCode != 0 {
            return "Error: FFprobe failed — \(result.stderr.prefix(300))"
        }

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Error: Could not parse FFprobe output."
        }

        // Build human-readable summary
        var lines: [String] = ["File: \(expanded)"]

        if let format = json["format"] as? [String: Any] {
            if let duration = format["duration"] as? String, let dur = Double(duration) {
                let mins = Int(dur) / 60
                let secs = Int(dur) % 60
                lines.append("Duration: \(mins)m \(secs)s (\(String(format: "%.1f", dur))s)")
            }
            if let size = format["size"] as? String, let bytes = Int64(size) {
                let mb = Double(bytes) / 1_048_576
                lines.append("Size: \(String(format: "%.1f", mb)) MB")
            }
            if let bitrate = format["bit_rate"] as? String, let br = Int(bitrate) {
                lines.append("Bitrate: \(br / 1000) kbps")
            }
            if let formatName = format["format_long_name"] as? String {
                lines.append("Format: \(formatName)")
            }
        }

        if let streams = json["streams"] as? [[String: Any]] {
            for stream in streams {
                let codecType = stream["codec_type"] as? String ?? "unknown"
                let codecName = stream["codec_name"] as? String ?? "unknown"

                if codecType == "video" {
                    let w = stream["width"] as? Int ?? 0
                    let h = stream["height"] as? Int ?? 0
                    let fps = stream["r_frame_rate"] as? String ?? "?"
                    lines.append("Video: \(codecName) \(w)x\(h) @ \(fps) fps")
                } else if codecType == "audio" {
                    let sampleRate = stream["sample_rate"] as? String ?? "?"
                    let channels = stream["channels"] as? Int ?? 0
                    lines.append("Audio: \(codecName) \(sampleRate) Hz, \(channels) channel(s)")
                } else if codecType == "subtitle" {
                    lines.append("Subtitle: \(codecName)")
                }
            }
        }

        // Also include raw JSON for programmatic use
        lines.append("\nRaw JSON:\n\(result.stdout)")

        return lines.joined(separator: "\n")
    }
}

// MARK: - FFmpeg Edit Video Tool

struct FFmpegEditVideoTool: ToolDefinition {
    let name = "ffmpeg_edit_video"
    let description = """
        Edit a video using an operations pipeline. Each operation transforms the video sequentially \
        when pipeline=true. Supported operations: trim, merge, overlay_text, overlay_image, add_audio, \
        speed, resize, crop, rotate, extract_audio, add_subtitles, fade, color_adjust, stabilize.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "spec": JSONSchema.string(description: """
                JSON spec for video editing. Example:
                {
                  "input": "/path/to/video.mp4",
                  "output": "edited_video.mp4",
                  "pipeline": true,
                  "operations": [
                    {"type": "trim", "start": 5.0, "end": 30.0},
                    {"type": "resize", "width": 1920, "height": 1080},
                    {"type": "overlay_text", "text": "My Title", "position": "center", "font_size": 72, "color": "white", "start": 0, "duration": 5},
                    {"type": "fade", "fade_in": 1.0, "fade_out": 1.0},
                    {"type": "add_audio", "audio_path": "/path/to/music.mp3", "volume": 0.3, "loop": true}
                  ]
                }
                Operations:
                • trim: start, end (seconds)
                • merge: inputs (array of paths), transition ("crossfade"/"none"), transition_duration (0.5)
                • overlay_text: text, position (center/top/bottom/top_left/bottom_right), font_size, color, bg_color, start, duration
                • overlay_image: image_path, x, y, width, height, start, duration, opacity
                • add_audio: audio_path, volume (0-1), loop (bool), mix_mode ("replace"/"mix")
                • speed: factor (0.25-4.0)
                • resize: width, height (or just one to maintain aspect ratio)
                • crop: x, y, width, height
                • rotate: angle (90, 180, 270)
                • extract_audio: format ("mp3"/"wav"/"aac")
                • add_subtitles: srt_path (or text+timestamps array)
                • fade: fade_in, fade_out (seconds)
                • color_adjust: brightness (−1 to 1), contrast (0-2), saturation (0-3)
                • stabilize: strength ("low"/"medium"/"high")
                """),
            "output_dir": JSONSchema.string(description: "Directory to save. Default: ~/Desktop"),
            "auto_open": JSONSchema.boolean(description: "Automatically open the video after editing. Default: true"),
        ], required: ["spec"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let specJSON = try requiredString("spec", from: args)
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath
        let autoOpen = optionalBool("auto_open", from: args) ?? true

        guard let specData = specJSON.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            return "Error: Invalid spec JSON."
        }

        guard spec["operations"] != nil else {
            return "Error: Spec must contain an 'operations' array."
        }

        let filename = (spec["output"] as? String) ?? "edited_video.mp4"
        let outputPath = (expandedDir as NSString).appendingPathComponent(
            filename.contains(".") ? filename : filename + ".mp4"
        )

        try? FileManager.default.createDirectory(atPath: expandedDir, withIntermediateDirectories: true)

        let result = try await FFmpegExecutor.runEngine(
            spec: specJSON, engine: "ffmpeg_engine", outputPath: outputPath, mode: "edit"
        )

        if let resultData = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
           let success = json["success"] as? Bool {
            if success {
                let path = json["path"] as? String ?? outputPath
                let duration = json["duration_seconds"] as? Double
                var msg = "Video edited successfully: \(path)"
                if let dur = duration { msg += " (\(String(format: "%.1f", dur))s)" }
                if autoOpen { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                return msg
            } else {
                let error = json["error"] as? String ?? "Unknown error"
                return "Video editing failed: \(error)"
            }
        }

        if FileManager.default.fileExists(atPath: outputPath) {
            if autoOpen { NSWorkspace.shared.open(URL(fileURLWithPath: outputPath)) }
            return "Video edited: \(outputPath)"
        }

        if !result.stderr.isEmpty {
            return "Failed: \(result.stderr.prefix(500))"
        }
        return "Failed: No output from ffmpeg_engine."
    }
}

// MARK: - Create Video Tool

struct CreateVideoTool: ToolDefinition {
    let name = "create_video"
    let description = """
        Create a video from scenes (images, title cards, video clips) with transitions, \
        Ken Burns animations, TTS narration, background music with ducking, and auto-subtitles. \
        Use plan_video first for videos longer than 2 minutes.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "spec": JSONSchema.string(description: """
                JSON spec for video creation. Example:
                {
                  "filename": "bakery_promo.mp4",
                  "resolution": [1920, 1080],
                  "fps": 30,
                  "scenes": [
                    {
                      "type": "title_card",
                      "duration": 4,
                      "text": "Welcome to Sweet Bakes",
                      "subtitle": "Artisan Pastries Since 2010",
                      "bg_color": "#2C1810",
                      "text_color": "#F5E6D3",
                      "font_size": 80
                    },
                    {
                      "type": "image",
                      "source": "/path/to/croissant.jpg",
                      "duration": 5,
                      "animation": "zoom_in",
                      "narration": "Our hand-crafted croissants are made fresh every morning."
                    },
                    {
                      "type": "image",
                      "source": "https://images.unsplash.com/photo-bakery...",
                      "duration": 5,
                      "animation": "pan_right",
                      "narration": "Using only the finest French butter."
                    },
                    {
                      "type": "video",
                      "source": "/path/to/baking_clip.mp4",
                      "trim_start": 2,
                      "trim_end": 10
                    },
                    {
                      "type": "title_card",
                      "duration": 3,
                      "text": "Visit Us Today",
                      "bg_color": "#2C1810",
                      "text_color": "#F5E6D3"
                    }
                  ],
                  "transitions": {"type": "crossfade", "duration": 0.8},
                  "audio": {
                    "narration": {"voice": "Samantha", "rate": 170},
                    "background_music": "/path/to/music.mp3",
                    "music_volume": 0.15,
                    "ducking": true
                  },
                  "subtitles": true
                }
                Scene types: image (with Ken Burns: zoom_in/zoom_out/pan_left/pan_right/pan_up), \
                title_card (text + optional subtitle on color bg), video (clip with optional trim), \
                color_card (solid color background).
                Transitions: crossfade, wipe_left, wipe_right, fade_black, none.
                Audio: narration text per scene or global, TTS via macOS say, background music with ducking.
                Auto-search: Use "search_query" instead of "source" in image scenes to auto-search for images.
                """),
            "output_dir": JSONSchema.string(description: "Directory to save. Default: ~/Desktop"),
            "style": JSONSchema.string(description: "Name of a saved video style profile to apply (from analyze_youtube_channel)."),
            "auto_open": JSONSchema.boolean(description: "Automatically open the video after creation. Default: true"),
        ], required: ["spec"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let specJSON = try requiredString("spec", from: args)
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath
        let style = optionalString("style", from: args)
        let autoOpen = optionalBool("auto_open", from: args) ?? true

        guard let specData = specJSON.data(using: .utf8),
              var spec = try? JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            return "Error: Invalid spec JSON."
        }

        guard var scenes = spec["scenes"] as? [[String: Any]] else {
            return "Error: Spec must contain a 'scenes' array."
        }

        // Auto-search: resolve search_query fields to real image URLs
        for i in 0..<scenes.count {
            if let query = scenes[i]["search_query"] as? String, scenes[i]["source"] == nil {
                let results = await ImageSearchService.search(query: query, count: 3, orientation: "landscape")
                if let best = results.first {
                    scenes[i]["source"] = best.url
                }
            }
        }
        spec["scenes"] = scenes

        // Re-serialize spec with resolved URLs
        guard let resolvedData = try? JSONSerialization.data(withJSONObject: spec),
              let resolvedJSON = String(data: resolvedData, encoding: .utf8) else {
            return "Error: Failed to serialize resolved spec."
        }

        let filename = (spec["filename"] as? String) ?? "video.mp4"
        let outputPath = (expandedDir as NSString).appendingPathComponent(
            filename.hasSuffix(".mp4") ? filename : filename + ".mp4"
        )

        try? FileManager.default.createDirectory(atPath: expandedDir, withIntermediateDirectories: true)

        var extraArgs: [String] = []
        if let styleName = style {
            let stylesDir = URL.applicationSupportDirectory
                .appendingPathComponent("Executer/video_styles")
            let stylePath = stylesDir.appendingPathComponent("video_style_\(styleName).json")
            if FileManager.default.fileExists(atPath: stylePath.path) {
                extraArgs += ["--style", stylePath.path]
            }
        }

        let result = try await FFmpegExecutor.runEngine(
            spec: resolvedJSON, engine: "ffmpeg_engine", outputPath: outputPath,
            mode: "create", extraArgs: extraArgs
        )

        if let resultData = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
           let success = json["success"] as? Bool {
            if success {
                let path = json["path"] as? String ?? outputPath
                let duration = json["duration_seconds"] as? Double
                let sceneCount = json["scenes"] as? Int
                var msg = "Video created: \(path)"
                if let dur = duration { msg += " (\(String(format: "%.1f", dur))s)" }
                if let sc = sceneCount { msg += ", \(sc) scenes" }
                if autoOpen { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                return msg
            } else {
                let error = json["error"] as? String ?? "Unknown error"
                return "Video creation failed: \(error)"
            }
        }

        if FileManager.default.fileExists(atPath: outputPath) {
            if autoOpen { NSWorkspace.shared.open(URL(fileURLWithPath: outputPath)) }
            return "Video created: \(outputPath)"
        }

        if !result.stderr.isEmpty {
            return "Failed: \(result.stderr.prefix(500))"
        }
        return "Failed: No output from ffmpeg_engine."
    }
}

// MARK: - Create Audio Tool

struct CreateAudioTool: ToolDefinition {
    let name = "create_audio"
    let description = """
        Create audio files with text-to-speech (TTS), music mixing, tone generation, and ducking. \
        Supports layered mixing (parallel tracks) or sequential concatenation.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "spec": JSONSchema.string(description: """
                JSON spec for audio creation. Example:
                {
                  "filename": "podcast_intro.m4a",
                  "tracks": [
                    {"type": "tts", "text": "Welcome to the show! Today we discuss...", "voice": "Samantha", "rate": 180},
                    {"type": "file", "path": "/path/to/jingle.mp3", "volume": 0.5, "fade_in": 1.0, "fade_out": 1.0},
                    {"type": "silence", "duration": 2.0},
                    {"type": "tone", "frequency": 440, "duration": 1.0, "volume": 0.3}
                  ],
                  "mix": "layer",
                  "ducking": true,
                  "output_format": "m4a"
                }
                Track types:
                • tts: text, voice (macOS voice name e.g. "Samantha", "Alex", "Daniel"), rate (words per minute)
                • file: path (local audio file), volume (0-1), fade_in, fade_out, loop (bool), trim_start, trim_end
                • silence: duration (seconds)
                • tone: frequency (Hz), duration, volume, waveform ("sine"/"square")
                Mix modes: "layer" (all tracks play simultaneously, with optional ducking) or "sequence" (tracks play one after another with optional crossfade).
                crossfade_duration: seconds of overlap between sequential tracks (default 0).
                ducking: when true, music tracks lower volume when TTS is playing (sidechaincompress).
                """),
            "output_dir": JSONSchema.string(description: "Directory to save. Default: ~/Desktop"),
            "auto_open": JSONSchema.boolean(description: "Automatically open the audio file after creation. Default: true"),
        ], required: ["spec"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let specJSON = try requiredString("spec", from: args)
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath
        let autoOpen = optionalBool("auto_open", from: args) ?? true

        guard let specData = specJSON.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            return "Error: Invalid spec JSON."
        }

        guard spec["tracks"] != nil else {
            return "Error: Spec must contain a 'tracks' array."
        }

        let filename = (spec["filename"] as? String) ?? "audio.m4a"
        let outputPath = (expandedDir as NSString).appendingPathComponent(filename)

        try? FileManager.default.createDirectory(atPath: expandedDir, withIntermediateDirectories: true)

        guard let ffmpeg = FFmpegExecutor.findFFmpeg() else {
            return "Error: FFmpeg not found. Run setup_ffmpeg first."
        }

        let python = PPTExecutor.findPython()
        let appSupport = URL.applicationSupportDirectory
        let execDir = appSupport.appendingPathComponent("Executer")

        FFmpegExecutor.ensureResource("audio_engine", ext: "py", in: execDir)

        let enginePath = execDir.appendingPathComponent("audio_engine.py")
        guard FileManager.default.fileExists(atPath: enginePath.path) else {
            return "Error: audio_engine.py not found. Reinstall the app."
        }

        let tempSpec = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_spec_\(UUID().uuidString).json")
        try specJSON.write(to: tempSpec, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempSpec) }

        let result = try await runAudioEngine(
            python: python, script: enginePath.path,
            specPath: tempSpec.path, output: outputPath, ffmpeg: ffmpeg
        )

        if let resultData = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
           let success = json["success"] as? Bool {
            if success {
                let path = json["path"] as? String ?? outputPath
                let duration = json["duration_seconds"] as? Double
                var msg = "Audio created: \(path)"
                if let dur = duration { msg += " (\(String(format: "%.1f", dur))s)" }
                if autoOpen { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                return msg
            } else {
                let error = json["error"] as? String ?? "Unknown error"
                return "Audio creation failed: \(error)"
            }
        }

        if FileManager.default.fileExists(atPath: outputPath) {
            if autoOpen { NSWorkspace.shared.open(URL(fileURLWithPath: outputPath)) }
            return "Audio created: \(outputPath)"
        }

        if !result.stderr.isEmpty {
            return "Failed: \(result.stderr.prefix(500))"
        }
        return "Failed: No output from audio_engine."
    }

    private func runAudioEngine(python: String, script: String, specPath: String,
                                output: String, ffmpeg: String) async throws -> FFmpegExecutor.ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = [script, "--spec", specPath, "--output", output, "--ffmpeg", ffmpeg]
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = ProcessInfo.processInfo.environment.merging([
                    "PYTHONIOENCODING": "utf-8",
                    "PYTHONUNBUFFERED": "1",
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
                ]) { _, new in new }

                do {
                    try process.run()
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(returning: FFmpegExecutor.ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Plan Video Tool

struct PlanVideoTool: ToolDefinition {
    let name = "plan_video"
    let description = "Generate a JSON template for a video project. Use this before create_video for longer or more complex videos. Returns a skeleton spec you can fill in."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "type": JSONSchema.enumString(
                description: "Video type/template.",
                values: ["explainer", "tutorial", "montage", "podcast", "vlog", "promo", "slideshow"]
            ),
            "topic": JSONSchema.string(description: "Topic or title of the video."),
            "duration_minutes": JSONSchema.number(description: "Target duration in minutes. Default: 2"),
            "scene_count": JSONSchema.integer(description: "Number of scenes. Default: auto-calculated from duration."),
        ], required: ["type", "topic"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let videoType = try requiredString("type", from: args)
        let topic = try requiredString("topic", from: args)
        let durationMinutes = optionalDouble("duration_minutes", from: args) ?? 2.0
        let durationSeconds = durationMinutes * 60
        let sceneCount = optionalInt("scene_count", from: args) ?? max(3, Int(durationMinutes * 4))

        let template: [String: Any]

        switch videoType {
        case "explainer":
            template = buildExplainerTemplate(topic: topic, scenes: sceneCount, duration: durationSeconds)
        case "tutorial":
            template = buildTutorialTemplate(topic: topic, scenes: sceneCount, duration: durationSeconds)
        case "montage":
            template = buildMontageTemplate(topic: topic, scenes: sceneCount, duration: durationSeconds)
        case "podcast":
            template = buildPodcastTemplate(topic: topic, duration: durationSeconds)
        case "promo":
            template = buildPromoTemplate(topic: topic, scenes: sceneCount, duration: durationSeconds)
        case "slideshow":
            template = buildSlideshowTemplate(topic: topic, scenes: sceneCount, duration: durationSeconds)
        default: // vlog
            template = buildVlogTemplate(topic: topic, scenes: sceneCount, duration: durationSeconds)
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: template, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "Error: Failed to generate template."
        }

        return """
            Video plan generated for "\(topic)" (\(videoType), ~\(String(format: "%.0f", durationMinutes)) min, \(sceneCount) scenes).

            Fill in the scene details below, then pass the spec to create_video:

            \(jsonString)

            Tips:
            • Use search_images to find real image URLs before creating the video
            • Add narration text to each scene for automatic TTS
            • Alternate transitions (crossfade, wipe_left, fade_black) for variety
            • Keep scenes at least 3 seconds to avoid feeling rushed
            """
    }

    // MARK: - Template Builders

    private func buildExplainerTemplate(topic: String, scenes: Int, duration: Double) -> [String: Any] {
        let sceneDuration = duration / Double(scenes)
        var sceneList: [[String: Any]] = []

        // Intro title
        sceneList.append([
            "type": "title_card", "duration": min(sceneDuration, 5),
            "text": topic, "subtitle": "Explained Simply",
            "bg_color": "#1a1a2e", "text_color": "#e94560"
        ])

        // Content scenes
        for i in 1..<(scenes - 1) {
            sceneList.append([
                "type": "image", "duration": sceneDuration,
                "source": "REPLACE_WITH_IMAGE_URL_\(i)",
                "animation": ["zoom_in", "pan_right", "zoom_out", "pan_left"][i % 4],
                "narration": "REPLACE: Explain point \(i) about \(topic)"
            ])
        }

        // Outro
        sceneList.append([
            "type": "title_card", "duration": min(sceneDuration, 4),
            "text": "Thanks for Watching", "subtitle": "Like & Subscribe",
            "bg_color": "#1a1a2e", "text_color": "#e94560"
        ])

        return [
            "filename": safeFilename(topic) + ".mp4",
            "resolution": [1920, 1080],
            "fps": 30,
            "scenes": sceneList,
            "transitions": ["type": "crossfade", "duration": 0.8],
            "audio": [
                "narration": ["voice": "Samantha", "rate": 170],
                "background_music": "REPLACE_WITH_MUSIC_PATH_OR_REMOVE",
                "music_volume": 0.12,
                "ducking": true
            ],
            "subtitles": true
        ]
    }

    private func buildTutorialTemplate(topic: String, scenes: Int, duration: Double) -> [String: Any] {
        let sceneDuration = duration / Double(scenes)
        var sceneList: [[String: Any]] = []

        sceneList.append(["type": "title_card", "duration": 4, "text": topic, "subtitle": "Step-by-Step Tutorial", "bg_color": "#0f3460", "text_color": "#e0e0e0"])

        for i in 1..<(scenes - 1) {
            sceneList.append([
                "type": "image", "duration": sceneDuration,
                "source": "REPLACE_WITH_SCREENSHOT_\(i)",
                "animation": "zoom_in",
                "narration": "REPLACE: Step \(i) — describe what to do"
            ])
        }

        sceneList.append(["type": "title_card", "duration": 3, "text": "You Did It!", "subtitle": "Summary & Next Steps", "bg_color": "#0f3460", "text_color": "#e0e0e0"])

        return [
            "filename": safeFilename(topic) + ".mp4",
            "resolution": [1920, 1080], "fps": 30,
            "scenes": sceneList,
            "transitions": ["type": "crossfade", "duration": 0.5],
            "audio": ["narration": ["voice": "Samantha", "rate": 160], "ducking": true],
            "subtitles": true
        ]
    }

    private func buildMontageTemplate(topic: String, scenes: Int, duration: Double) -> [String: Any] {
        let sceneDuration = duration / Double(scenes)
        var sceneList: [[String: Any]] = []

        for i in 0..<scenes {
            let animations = ["zoom_in", "pan_right", "zoom_out", "pan_left", "pan_up"]
            sceneList.append([
                "type": "image", "duration": sceneDuration,
                "source": "REPLACE_WITH_IMAGE_\(i + 1)",
                "animation": animations[i % animations.count]
            ])
        }

        return [
            "filename": safeFilename(topic) + ".mp4",
            "resolution": [1920, 1080], "fps": 30,
            "scenes": sceneList,
            "transitions": ["type": "crossfade", "duration": 1.0],
            "audio": [
                "background_music": "REPLACE_WITH_MUSIC_PATH",
                "music_volume": 0.8
            ]
        ]
    }

    private func buildPodcastTemplate(topic: String, duration: Double) -> [String: Any] {
        return [
            "filename": safeFilename(topic) + ".mp4",
            "resolution": [1920, 1080], "fps": 30,
            "scenes": [
                ["type": "title_card", "duration": 5, "text": topic, "subtitle": "Podcast Episode", "bg_color": "#1a1a1a", "text_color": "#ffffff"],
                ["type": "image", "duration": duration - 8, "source": "REPLACE_WITH_PODCAST_ARTWORK", "animation": "none", "narration": "REPLACE: Full podcast narration text here"],
                ["type": "title_card", "duration": 3, "text": "Thanks for Listening", "bg_color": "#1a1a1a", "text_color": "#ffffff"]
            ],
            "transitions": ["type": "crossfade", "duration": 0.5],
            "audio": ["narration": ["voice": "Samantha", "rate": 165], "ducking": true],
            "subtitles": true
        ]
    }

    private func buildPromoTemplate(topic: String, scenes: Int, duration: Double) -> [String: Any] {
        let sceneDuration = duration / Double(scenes)
        var sceneList: [[String: Any]] = []

        sceneList.append(["type": "title_card", "duration": min(sceneDuration, 3), "text": topic, "bg_color": "#e94560", "text_color": "#ffffff", "font_size": 90])

        for i in 1..<(scenes - 1) {
            let animations = ["zoom_in", "pan_right", "zoom_out"]
            sceneList.append([
                "type": "image", "duration": sceneDuration,
                "source": "REPLACE_WITH_PROMO_IMAGE_\(i)",
                "animation": animations[i % animations.count],
                "narration": "REPLACE: Highlight feature \(i)"
            ])
        }

        sceneList.append(["type": "title_card", "duration": min(sceneDuration, 4), "text": "Get Started Today", "subtitle": "REPLACE_WITH_CTA_URL", "bg_color": "#e94560", "text_color": "#ffffff"])

        return [
            "filename": safeFilename(topic) + ".mp4",
            "resolution": [1920, 1080], "fps": 30,
            "scenes": sceneList,
            "transitions": ["type": "wipe_left", "duration": 0.6],
            "audio": [
                "narration": ["voice": "Samantha", "rate": 180],
                "background_music": "REPLACE_WITH_UPBEAT_MUSIC",
                "music_volume": 0.2, "ducking": true
            ],
            "subtitles": true
        ]
    }

    private func buildSlideshowTemplate(topic: String, scenes: Int, duration: Double) -> [String: Any] {
        let sceneDuration = duration / Double(scenes)
        var sceneList: [[String: Any]] = []

        for i in 0..<scenes {
            let animations = ["zoom_in", "pan_right", "zoom_out", "pan_left"]
            sceneList.append([
                "type": "image", "duration": sceneDuration,
                "source": "REPLACE_WITH_PHOTO_\(i + 1)",
                "animation": animations[i % animations.count]
            ])
        }

        return [
            "filename": safeFilename(topic) + ".mp4",
            "resolution": [1920, 1080], "fps": 30,
            "scenes": sceneList,
            "transitions": ["type": "crossfade", "duration": 1.2],
            "audio": [
                "background_music": "REPLACE_WITH_MUSIC_PATH",
                "music_volume": 0.7
            ]
        ]
    }

    private func buildVlogTemplate(topic: String, scenes: Int, duration: Double) -> [String: Any] {
        let sceneDuration = duration / Double(scenes)
        var sceneList: [[String: Any]] = []

        sceneList.append(["type": "title_card", "duration": 3, "text": topic, "subtitle": "Vlog", "bg_color": "#2d2d2d", "text_color": "#ffd700"])

        for i in 1..<(scenes - 1) {
            sceneList.append([
                "type": "video", "duration": sceneDuration,
                "source": "REPLACE_WITH_CLIP_\(i)",
                "narration": "REPLACE: Describe what's happening"
            ])
        }

        sceneList.append(["type": "title_card", "duration": 3, "text": "See You Next Time!", "bg_color": "#2d2d2d", "text_color": "#ffd700"])

        return [
            "filename": safeFilename(topic) + ".mp4",
            "resolution": [1920, 1080], "fps": 30,
            "scenes": sceneList,
            "transitions": ["type": "crossfade", "duration": 0.5],
            "audio": ["narration": ["voice": "Samantha", "rate": 175], "ducking": true],
            "subtitles": true
        ]
    }

    private func safeFilename(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)
    }
}

// MARK: - Quick Video Tool (One-Shot)

struct QuickVideoTool: ToolDefinition {
    let name = "quick_video"
    let description = """
        Create a complete video in one shot — just provide a topic and optional narration. \
        Automatically searches for images, generates scenes with Ken Burns animations, \
        adds TTS narration and subtitles, and opens the result. No spec needed.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "topic": JSONSchema.string(description: "Topic/title of the video (e.g. 'The History of Coffee', 'My Bakery Promo')"),
            "narration": JSONSchema.string(description: "Full narration script. Split into paragraphs — each paragraph becomes one scene. If omitted, generates title-only scenes."),
            "duration_seconds": JSONSchema.integer(description: "Target duration in seconds. Default: auto-calculated from narration length, or 30s."),
            "type": JSONSchema.enumString(description: "Video style.", values: ["explainer", "promo", "montage", "slideshow"]),
            "image_queries": JSONSchema.string(description: "Comma-separated image search queries, one per scene. If omitted, auto-derived from narration."),
            "voice": JSONSchema.string(description: "TTS voice name. Default: Samantha"),
            "output_dir": JSONSchema.string(description: "Directory to save. Default: ~/Desktop"),
        ], required: ["topic"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let topic = try requiredString("topic", from: args)
        let narration = optionalString("narration", from: args)
        let targetDuration = optionalInt("duration_seconds", from: args)
        let videoType = optionalString("type", from: args) ?? "explainer"
        let imageQueriesRaw = optionalString("image_queries", from: args)
        let voice = optionalString("voice", from: args) ?? "Samantha"
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath

        // Split narration into scenes (by paragraph)
        var paragraphs: [String] = []
        if let narr = narration {
            paragraphs = narr.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if paragraphs.isEmpty {
            paragraphs = [""]  // At least one scene
        }

        // Derive image queries
        var imageQueries: [String]
        if let raw = imageQueriesRaw {
            imageQueries = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            // Auto-derive from narration: use first few words of each paragraph + topic
            imageQueries = paragraphs.map { para -> String in
                if para.isEmpty { return topic }
                let words = para.components(separatedBy: " ").prefix(5).joined(separator: " ")
                return words
            }
        }

        // Calculate durations
        let sceneDuration: Double
        if let target = targetDuration {
            sceneDuration = Double(target) / Double(paragraphs.count + 2) // +2 for intro/outro
        } else if narration != nil {
            // Estimate from narration: ~150 words per minute TTS
            let wordCount = paragraphs.joined(separator: " ").components(separatedBy: " ").count
            let estimatedSeconds = max(Double(wordCount) / 2.5, 4.0) // ~2.5 words/sec
            sceneDuration = estimatedSeconds / Double(paragraphs.count)
        } else {
            sceneDuration = 5.0
        }

        // Build scenes
        var scenes: [[String: Any]] = []
        let animations = ["zoom_in", "pan_right", "zoom_out", "pan_left", "pan_up"]
        let colors: [(String, String)] = [
            ("#1a1a2e", "#e94560"), ("#0f3460", "#e0e0e0"), ("#2C1810", "#F5E6D3"),
            ("#16213e", "#e94560"), ("#1b262c", "#bbe1fa"),
        ]

        // Intro title card
        let (bg, fg) = colors[0]
        scenes.append([
            "type": "title_card", "duration": min(sceneDuration, 4),
            "text": topic, "subtitle": videoType == "promo" ? "Check It Out" : "",
            "bg_color": bg, "text_color": fg, "font_size": 72
        ])

        // Search for images in parallel
        let searchResults = await withTaskGroup(of: (Int, String?).self) { group -> [Int: String] in
            for (i, query) in imageQueries.prefix(paragraphs.count).enumerated() {
                group.addTask {
                    let results = await ImageSearchService.search(query: query, count: 3, orientation: "landscape")
                    return (i, results.first?.url)
                }
            }
            var dict: [Int: String] = [:]
            for await (i, url) in group {
                if let u = url { dict[i] = u }
            }
            return dict
        }

        // Content scenes
        for (i, para) in paragraphs.enumerated() {
            var scene: [String: Any] = [
                "type": "image",
                "duration": max(sceneDuration, 4),
                "animation": animations[i % animations.count],
            ]
            if let url = searchResults[i] {
                scene["source"] = url
            } else {
                // Fallback: use a search_query for the engine to resolve
                scene["search_query"] = imageQueries.indices.contains(i) ? imageQueries[i] : topic
            }
            if !para.isEmpty {
                scene["narration"] = para
            }
            scenes.append(scene)
        }

        // Outro title card
        let (bg2, fg2) = colors[1]
        scenes.append([
            "type": "title_card", "duration": 3,
            "text": videoType == "promo" ? "Get Started Today" : "Thanks for Watching",
            "bg_color": bg2, "text_color": fg2
        ])

        // Build full spec
        let filename = topic.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression) + ".mp4"

        let spec: [String: Any] = [
            "filename": filename,
            "resolution": [1920, 1080],
            "fps": 30,
            "scenes": scenes,
            "transitions": ["type": videoType == "montage" ? "crossfade" : "crossfade", "duration": 0.8],
            "audio": [
                "narration": ["voice": voice, "rate": 170],
                "music_volume": 0.12,
                "ducking": true
            ],
            "subtitles": narration != nil
        ]

        guard let specData = try? JSONSerialization.data(withJSONObject: spec),
              let specJSON = String(data: specData, encoding: .utf8) else {
            return "Error: Failed to build video spec."
        }

        let outputPath = (expandedDir as NSString).appendingPathComponent(filename)
        try? FileManager.default.createDirectory(atPath: expandedDir, withIntermediateDirectories: true)

        let result = try await FFmpegExecutor.runEngine(
            spec: specJSON, engine: "ffmpeg_engine", outputPath: outputPath, mode: "create"
        )

        if let resultData = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
           let success = json["success"] as? Bool {
            if success {
                let path = json["path"] as? String ?? outputPath
                let duration = json["duration_seconds"] as? Double
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                var msg = "Video created and opened: \(path)"
                if let dur = duration { msg += " (\(String(format: "%.1f", dur))s)" }
                msg += ", \(scenes.count) scenes"
                return msg
            } else {
                return "Video creation failed: \(json["error"] as? String ?? "Unknown error")"
            }
        }

        if FileManager.default.fileExists(atPath: outputPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: outputPath))
            return "Video created: \(outputPath)"
        }
        return "Failed: \(result.stderr.prefix(500))"
    }
}

// MARK: - Create Podcast Tool (One-Shot)

struct CreatePodcastTool: ToolDefinition {
    let name = "create_podcast"
    let description = """
        Create a podcast episode in one shot. Provide narration text and it handles everything: \
        TTS generation, background music mixing with ducking, intro/outro, and outputs a ready-to-play audio file.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "Podcast episode title."),
            "narration": JSONSchema.string(description: "Full episode narration/script text. This will be converted to speech."),
            "voice": JSONSchema.string(description: "TTS voice. Default: Samantha. Try: Alex, Daniel, Fiona, Karen, Moira, Tessa, Rishi, Veena"),
            "voice_rate": JSONSchema.integer(description: "Speech rate in words per minute. Default: 165 (conversational)."),
            "background_music": JSONSchema.string(description: "Path to background music file. Optional — if omitted, creates speech-only episode."),
            "music_volume": JSONSchema.number(description: "Background music volume 0-1. Default: 0.12"),
            "output_format": JSONSchema.enumString(description: "Output format.", values: ["m4a", "mp3", "wav"]),
            "output_dir": JSONSchema.string(description: "Directory to save. Default: ~/Desktop"),
        ], required: ["title", "narration"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = try requiredString("title", from: args)
        let narration = try requiredString("narration", from: args)
        let voice = optionalString("voice", from: args) ?? "Samantha"
        let voiceRate = optionalInt("voice_rate", from: args) ?? 165
        let bgMusic = optionalString("background_music", from: args)
        let musicVolume = optionalDouble("music_volume", from: args) ?? 0.12
        let outputFormat = optionalString("output_format", from: args) ?? "m4a"
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath

        guard FFmpegExecutor.findFFmpeg() != nil else {
            return "Error: FFmpeg not found. Run setup_ffmpeg first."
        }

        // Build a simplified audio spec
        var tracks: [[String: Any]] = []

        // Main narration track
        tracks.append([
            "type": "tts",
            "text": narration,
            "voice": voice,
            "rate": voiceRate
        ])

        // Background music track (if provided)
        if let music = bgMusic {
            let expanded = NSString(string: music).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                tracks.append([
                    "type": "file",
                    "path": expanded,
                    "volume": musicVolume,
                    "loop": true,
                    "fade_in": 2.0,
                    "fade_out": 3.0
                ])
            }
        }

        let filename = title.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression) + ".\(outputFormat)"

        let spec: [String: Any] = [
            "filename": filename,
            "tracks": tracks,
            "mix": bgMusic != nil ? "layer" : "sequence",
            "ducking": bgMusic != nil,
            "output_format": outputFormat
        ]

        guard let specData = try? JSONSerialization.data(withJSONObject: spec),
              let specJSON = String(data: specData, encoding: .utf8) else {
            return "Error: Failed to build audio spec."
        }

        // Use CreateAudioTool's pipeline
        let audioTool = CreateAudioTool()
        let wrappedArgs: [String: Any] = [
            "spec": specJSON,
            "output_dir": outputDir,
            "auto_open": true
        ]
        guard let argsData = try? JSONSerialization.data(withJSONObject: wrappedArgs),
              let argsJSON = String(data: argsData, encoding: .utf8) else {
            return "Error: Failed to serialize arguments."
        }

        return try await audioTool.execute(arguments: argsJSON)
    }
}
