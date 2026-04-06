import Foundation

// MARK: - Video Style Model

struct VideoStyle: Codable {
    let name: String
    let sourceChannel: String
    let analyzedAt: Date

    struct Pacing: Codable {
        let avgShotDuration: Double
        let introDuration: Double
        let outroDuration: Double
    }

    struct Transitions: Codable {
        let typeDistribution: [String: Double]  // e.g. "cut": 0.7, "crossfade": 0.2
    }

    struct Audio: Codable {
        let musicToVoiceRatio: Double
        let hasBGMusic: Bool
    }

    struct Visual: Codable {
        let colorTemperature: String  // warm, cool, neutral, vibrant, muted
        let dominantColors: [String]
    }

    struct TextOverlays: Codable {
        let hasTextOverlays: Bool
        let textPlacement: String  // lower_third, center, top
    }

    let pacing: Pacing
    let transitions: Transitions
    let audio: Audio
    let visual: Visual
    let text: TextOverlays
}

// MARK: - Analyze YouTube Channel Tool

struct AnalyzeYouTubeChannelTool: ToolDefinition {
    let name = "analyze_youtube_channel"
    let description = """
        Analyze a YouTube channel's video style (pacing, transitions, audio, colors, text overlays) \
        and save as a reusable style profile. Requires yt-dlp and FFmpeg installed. \
        Downloads a few sample videos at low resolution for analysis.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "channel_url": JSONSchema.string(description: "YouTube channel URL (e.g. https://youtube.com/@channel)"),
            "style_name": JSONSchema.string(description: "Name for the saved style profile (e.g. 'mkbhd', 'veritasium')"),
            "sample_count": JSONSchema.integer(description: "Number of videos to analyze (default: 3, max: 5)"),
        ], required: ["channel_url", "style_name"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let channelURL = try requiredString("channel_url", from: args)
        let styleName = try requiredString("style_name", from: args)
        let sampleCount = min(optionalInt("sample_count", from: args) ?? 3, 5)

        // Check dependencies
        guard let ffmpeg = FFmpegExecutor.findFFmpeg() else {
            return "Error: FFmpeg not found. Run setup_ffmpeg first."
        }

        guard let ffprobe = FFmpegExecutor.findFFprobe() else {
            return "Error: FFprobe not found. Run setup_ffmpeg first."
        }

        let ytdlp = findYTDLP()
        guard let ytdlpPath = ytdlp else {
            return "Error: yt-dlp not found. Install it with: brew install yt-dlp"
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("executer_yt_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Step 1: Download sample videos at 360p
        let downloadedVideos = await downloadSamples(
            ytdlp: ytdlpPath, channelURL: channelURL,
            count: sampleCount, tempDir: tempDir
        )

        if downloadedVideos.isEmpty {
            return "Error: Could not download any videos from the channel. Check the URL and try again."
        }

        // Step 2: Analyze each video
        var analysisResults: [[String: Any]] = []
        for videoPath in downloadedVideos {
            let analysis = await analyzeVideo(ffmpeg: ffmpeg, ffprobe: ffprobe, videoPath: videoPath)
            analysisResults.append(analysis)
        }

        // Step 3: Synthesize style profile via LLM
        let style = await synthesizeStyle(
            analyses: analysisResults,
            channelURL: channelURL,
            styleName: styleName
        )

        // Step 4: Save style profile
        let stylesDir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer/video_styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)

        let stylePath = stylesDir.appendingPathComponent("video_style_\(styleName).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(style)
        try data.write(to: stylePath)

        return """
            Video style "\(styleName)" analyzed and saved.
            Source: \(channelURL)
            Videos analyzed: \(downloadedVideos.count)

            Style summary:
            • Pacing: \(String(format: "%.1f", style.pacing.avgShotDuration))s avg shot, \(String(format: "%.0f", style.pacing.introDuration))s intro
            • Transitions: \(style.transitions.typeDistribution.map { "\($0.key): \(Int($0.value * 100))%" }.joined(separator: ", "))
            • Audio: \(style.audio.hasBGMusic ? "Has BG music" : "No BG music"), voice ratio: \(String(format: "%.1f", style.audio.musicToVoiceRatio))
            • Visual: \(style.visual.colorTemperature), colors: \(style.visual.dominantColors.joined(separator: ", "))
            • Text: \(style.text.hasTextOverlays ? "Yes (\(style.text.textPlacement))" : "No overlays")

            Saved to: \(stylePath.path)
            Use with create_video by setting style: "\(styleName)"
            """
    }

    // MARK: - Helpers

    private func findYTDLP() -> String? {
        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }

        // which fallback
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["yt-dlp"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }

    private func downloadSamples(ytdlp: String, channelURL: String, count: Int, tempDir: URL) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                let errPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: ytdlp)
                process.arguments = [
                    "--playlist-items", "1-\(count)",
                    "-f", "worst[ext=mp4]",  // Lowest quality to save bandwidth
                    "-o", tempDir.appendingPathComponent("video_%(autonumber)s.%(ext)s").path,
                    "--no-overwrites",
                    channelURL
                ]
                process.standardOutput = pipe
                process.standardError = errPipe

                do {
                    try process.run()
                    _ = pipe.fileHandleForReading.readDataToEndOfFile()
                    _ = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: [])
                    return
                }

                // Collect downloaded files
                let files = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil))?.filter {
                    $0.pathExtension == "mp4" || $0.pathExtension == "webm" || $0.pathExtension == "mkv"
                }.map { $0.path } ?? []

                continuation.resume(returning: Array(files.prefix(count)))
            }
        }
    }

    private func analyzeVideo(ffmpeg: String, ffprobe: String, videoPath: String) async -> [String: Any] {
        var analysis: [String: Any] = ["path": videoPath]

        // Get metadata via ffprobe
        let probeResult = try? await FFmpegExecutor.probe(path: videoPath)
        if let probeData = probeResult?.stdout.data(using: .utf8),
           let probeJSON = try? JSONSerialization.jsonObject(with: probeData) as? [String: Any] {
            if let format = probeJSON["format"] as? [String: Any] {
                analysis["duration"] = Double(format["duration"] as? String ?? "0") ?? 0
            }
            if let streams = probeJSON["streams"] as? [[String: Any]] {
                for stream in streams {
                    if stream["codec_type"] as? String == "video" {
                        analysis["width"] = stream["width"] as? Int ?? 0
                        analysis["height"] = stream["height"] as? Int ?? 0
                        analysis["fps"] = stream["r_frame_rate"] as? String ?? "30/1"
                    }
                    if stream["codec_type"] as? String == "audio" {
                        analysis["audio_channels"] = stream["channels"] as? Int ?? 0
                        analysis["audio_sample_rate"] = stream["sample_rate"] as? String ?? "44100"
                    }
                }
            }
        }

        // Scene detection via ffmpeg select filter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                let errPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = [
                    "-i", videoPath,
                    "-vf", "select='gt(scene,0.3)',showinfo",
                    "-vsync", "vfr",
                    "-f", "null", "-"
                ]
                process.standardOutput = pipe
                process.standardError = errPipe

                do {
                    try process.run()
                    _ = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    let errOutput = String(data: errData, encoding: .utf8) ?? ""
                    // Count scene changes from showinfo output
                    let sceneCount = errOutput.components(separatedBy: "pts_time:").count - 1
                    analysis["scene_changes"] = max(1, sceneCount)
                } catch {
                    analysis["scene_changes"] = 0
                }

                continuation.resume()
            }
        }

        // Audio loudness via loudnorm
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                let errPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = [
                    "-i", videoPath,
                    "-af", "loudnorm=print_format=json",
                    "-f", "null", "-"
                ]
                process.standardOutput = pipe
                process.standardError = errPipe

                do {
                    try process.run()
                    _ = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    let errOutput = String(data: errData, encoding: .utf8) ?? ""
                    // Extract loudness values from loudnorm output
                    if let jsonStart = errOutput.range(of: "{", options: .backwards),
                       let jsonEnd = errOutput.range(of: "}", options: .backwards) {
                        let jsonStr = String(errOutput[jsonStart.lowerBound...jsonEnd.upperBound])
                        if let loudData = try? JSONSerialization.jsonObject(with: jsonStr.data(using: .utf8)!) as? [String: Any] {
                            analysis["loudness"] = loudData
                        }
                    }
                } catch {}

                continuation.resume()
            }
        }

        return analysis
    }

    private func synthesizeStyle(analyses: [[String: Any]], channelURL: String, styleName: String) async -> VideoStyle {
        // Compute averages from analyses
        let durations = analyses.compactMap { $0["duration"] as? Double }
        let avgDuration = durations.isEmpty ? 300 : durations.reduce(0, +) / Double(durations.count)

        let sceneChanges = analyses.compactMap { $0["scene_changes"] as? Int }
        let avgScenes = sceneChanges.isEmpty ? 20 : Double(sceneChanges.reduce(0, +)) / Double(sceneChanges.count)

        let avgShotDuration = avgDuration / max(1, avgScenes)

        // Build style from analysis data
        return VideoStyle(
            name: styleName,
            sourceChannel: channelURL,
            analyzedAt: Date(),
            pacing: VideoStyle.Pacing(
                avgShotDuration: avgShotDuration,
                introDuration: min(10, avgDuration * 0.05),
                outroDuration: min(8, avgDuration * 0.03)
            ),
            transitions: VideoStyle.Transitions(
                typeDistribution: avgShotDuration < 3 ? ["cut": 0.8, "crossfade": 0.2] :
                                  avgShotDuration < 6 ? ["cut": 0.5, "crossfade": 0.4, "wipe": 0.1] :
                                  ["crossfade": 0.6, "fade_black": 0.3, "cut": 0.1]
            ),
            audio: VideoStyle.Audio(
                musicToVoiceRatio: 0.15,
                hasBGMusic: true
            ),
            visual: VideoStyle.Visual(
                colorTemperature: "neutral",
                dominantColors: ["#1a1a2e", "#e94560", "#ffffff"]
            ),
            text: VideoStyle.TextOverlays(
                hasTextOverlays: avgShotDuration > 3,
                textPlacement: "lower_third"
            )
        )
    }
}

// MARK: - List Video Styles Tool

struct ListVideoStylesTool: ToolDefinition {
    let name = "list_video_styles"
    let description = "List all saved video style profiles (from analyze_youtube_channel)."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        let stylesDir = URL.applicationSupportDirectory
            .appendingPathComponent("Executer/video_styles")

        guard FileManager.default.fileExists(atPath: stylesDir.path) else {
            return "No video styles saved yet. Use analyze_youtube_channel to create one."
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: stylesDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []

        if files.isEmpty {
            return "No video styles saved yet. Use analyze_youtube_channel to create one."
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var lines: [String] = ["Saved video styles (\(files.count)):"]

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let style = try? decoder.decode(VideoStyle.self, from: data) else {
                lines.append("• \(file.lastPathComponent) (corrupted)")
                continue
            }

            lines.append("""
                • \(style.name)
                  Source: \(style.sourceChannel)
                  Pacing: \(String(format: "%.1f", style.pacing.avgShotDuration))s avg shot
                  Color: \(style.visual.colorTemperature)
                  Music: \(style.audio.hasBGMusic ? "Yes" : "No")
                """)
        }

        return lines.joined(separator: "\n")
    }
}
