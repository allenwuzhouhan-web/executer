import AppKit
import Foundation

// MARK: - YouTube Executor Helpers

enum YouTubeExecutor {

    /// Cached yt-dlp path — detected once, reused.
    private static var cachedYTDLPPath: String?

    /// Find yt-dlp executable. Returns nil if not installed.
    static func findYTDLP() -> String? {
        if let cached = cachedYTDLPPath { return cached }

        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedYTDLPPath = path
                return path
            }
        }

        // Try `which yt-dlp`
        let whichProcess = Process()
        let pipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["yt-dlp"]
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        try? whichProcess.run()
        whichProcess.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty && FileManager.default.isExecutableFile(atPath: output) {
            cachedYTDLPPath = output
            return output
        }

        return nil
    }

    /// Run yt-dlp with arguments. Returns ProcessResult.
    /// CRITICAL: Reads pipes BEFORE waitUntilExit to avoid deadlock.
    static func runYTDLP(args: [String], timeoutSeconds: Int = 300) async throws -> FFmpegExecutor.ProcessResult {
        guard let ytdlp = findYTDLP() else {
            return FFmpegExecutor.ProcessResult(
                stdout: "", stderr: "yt-dlp not found. Run setup_ytdlp first.", exitCode: 1
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: ytdlp)
                process.arguments = args
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = ProcessInfo.processInfo.environment.merging([
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

                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timer.cancel()

                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus == SIGTERM || process.terminationStatus == SIGKILL {
                        continuation.resume(returning: FFmpegExecutor.ProcessResult(
                            stdout: "", stderr: "yt-dlp timed out after \(timeoutSeconds) seconds.", exitCode: process.terminationStatus
                        ))
                        return
                    }

                    continuation.resume(returning: FFmpegExecutor.ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Download YouTube Video Tool

struct DownloadYouTubeTool: ToolDefinition {
    let name = "download_youtube"
    let description = """
        Download a video or audio from YouTube (or other supported sites) using yt-dlp. \
        Supports quality selection, audio-only extraction, and subtitle download. \
        The downloaded file is saved to Desktop by default and auto-opened.
        """

    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "YouTube URL (video, playlist, or channel). Also supports Twitter, TikTok, Instagram, Vimeo, etc."),
            "format": JSONSchema.enumString(description: "Download format. Default: best_video", values: [
                "best_video", "720p", "480p", "360p", "audio_only", "mp3"
            ]),
            "filename": JSONSchema.string(description: "Custom filename (without extension). Default: auto from video title."),
            "subtitles": JSONSchema.boolean(description: "Also download subtitles if available. Default: false"),
            "playlist_items": JSONSchema.string(description: "For playlists: item range e.g. '1-3' to download first 3 videos. Default: downloads all."),
            "output_dir": JSONSchema.string(description: "Directory to save. Default: ~/Desktop"),
            "auto_open": JSONSchema.boolean(description: "Open the file after download. Default: true"),
        ], required: ["url"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let url = try requiredString("url", from: args)
        let format = optionalString("format", from: args) ?? "best_video"
        let customFilename = optionalString("filename", from: args)
        let subtitles = optionalBool("subtitles", from: args) ?? false
        let playlistItems = optionalString("playlist_items", from: args)
        let outputDir = optionalString("output_dir", from: args) ?? "~/Desktop"
        let expandedDir = NSString(string: outputDir).expandingTildeInPath
        let autoOpen = optionalBool("auto_open", from: args) ?? true

        guard YouTubeExecutor.findYTDLP() != nil else {
            return "Error: yt-dlp not found. Run setup_ytdlp to install it."
        }

        try? FileManager.default.createDirectory(atPath: expandedDir, withIntermediateDirectories: true)

        // Build output template
        let outputTemplate: String
        if let name = customFilename {
            outputTemplate = (expandedDir as NSString).appendingPathComponent("\(name).%(ext)s")
        } else {
            outputTemplate = (expandedDir as NSString).appendingPathComponent("%(title)s.%(ext)s")
        }

        // Build yt-dlp arguments
        var ytArgs: [String] = []

        // Format selection
        switch format {
        case "audio_only":
            ytArgs += ["-f", "bestaudio", "-x", "--audio-format", "m4a"]
        case "mp3":
            ytArgs += ["-f", "bestaudio", "-x", "--audio-format", "mp3"]
        case "720p":
            ytArgs += ["-f", "bestvideo[height<=720]+bestaudio/best[height<=720]"]
        case "480p":
            ytArgs += ["-f", "bestvideo[height<=480]+bestaudio/best[height<=480]"]
        case "360p":
            ytArgs += ["-f", "bestvideo[height<=360]+bestaudio/best[height<=360]"]
        default: // best_video
            ytArgs += ["-f", "bestvideo+bestaudio/best"]
        }

        // Merge to mp4 for video formats
        if format != "audio_only" && format != "mp3" {
            ytArgs += ["--merge-output-format", "mp4"]
        }

        // Subtitles
        if subtitles {
            ytArgs += ["--write-sub", "--write-auto-sub", "--sub-lang", "en", "--embed-subs"]
        }

        // Playlist items
        if let items = playlistItems {
            ytArgs += ["--playlist-items", items]
        }

        // FFmpeg location (for merging/conversion)
        if let ffmpeg = FFmpegExecutor.findFFmpeg() {
            let ffmpegDir = (ffmpeg as NSString).deletingLastPathComponent
            ytArgs += ["--ffmpeg-location", ffmpegDir]
        }

        ytArgs += [
            "-o", outputTemplate,
            "--no-overwrites",
            "--restrict-filenames",
            "--print", "after_move:filepath",  // Print final file path
            url
        ]

        let result = try await YouTubeExecutor.runYTDLP(args: ytArgs, timeoutSeconds: 600)

        if result.exitCode != 0 {
            let errMsg = result.stderr.isEmpty ? "Unknown error" : String(result.stderr.prefix(500))
            return "Download failed: \(errMsg)"
        }

        // Parse downloaded file path from stdout (--print after_move:filepath)
        let downloadedPaths = result.stdout.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }

        if let firstPath = downloadedPaths.first {
            // Get file size
            let attrs = try? FileManager.default.attributesOfItem(atPath: firstPath)
            let fileSize = attrs?[.size] as? Int64 ?? 0
            let sizeMB = Double(fileSize) / 1_048_576

            if autoOpen {
                NSWorkspace.shared.open(URL(fileURLWithPath: firstPath))
            }

            var msg = "Downloaded: \(firstPath) (\(String(format: "%.1f", sizeMB)) MB)"
            if downloadedPaths.count > 1 {
                msg += "\n+ \(downloadedPaths.count - 1) more file(s)"
                for extra in downloadedPaths.dropFirst() {
                    msg += "\n  \(extra)"
                }
            }
            return msg
        }

        // Fallback: scan output dir for recently created files
        let recentFiles = findRecentFiles(in: expandedDir, withinSeconds: 60)
        if let recent = recentFiles.first {
            if autoOpen { NSWorkspace.shared.open(URL(fileURLWithPath: recent)) }
            return "Downloaded: \(recent)"
        }

        return "Download appears complete but could not locate output file. Check \(expandedDir)"
    }

    private func findRecentFiles(in directory: String, withinSeconds: TimeInterval) -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        let now = Date()
        let videoExts: Set<String> = ["mp4", "mkv", "webm", "m4a", "mp3", "wav"]

        return files.compactMap { file -> (String, Date)? in
            let path = (directory as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modDate) < withinSeconds,
                  videoExts.contains((file as NSString).pathExtension.lowercased()) else { return nil }
            return (path, modDate)
        }
        .sorted { $0.1 > $1.1 }
        .map { $0.0 }
    }
}

// MARK: - Setup yt-dlp Tool

struct SetupYTDLPTool: ToolDefinition {
    let name = "setup_ytdlp"
    let description = "Check if yt-dlp is installed and report its version. Attempts to install via Homebrew if missing."

    var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    func execute(arguments: String) async throws -> String {
        if let ytdlp = YouTubeExecutor.findYTDLP() {
            let version = try await getVersion(executable: ytdlp)
            var report = "yt-dlp installed: \(ytdlp)\nVersion: \(version)"

            // Also check ffmpeg (needed for merging)
            if let ffmpeg = FFmpegExecutor.findFFmpeg() {
                report += "\nFFmpeg: \(ffmpeg) (needed for format merging)"
            } else {
                report += "\nWarning: FFmpeg not found. Some format merging may fail. Run setup_ffmpeg to install."
            }

            return report
        }

        // Try to install via Homebrew
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for brewPath in brewPaths {
            if FileManager.default.isExecutableFile(atPath: brewPath) {
                return await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let process = Process()
                        let pipe = Pipe()
                        let errPipe = Pipe()
                        process.executableURL = URL(fileURLWithPath: brewPath)
                        process.arguments = ["install", "yt-dlp"]
                        process.standardOutput = pipe
                        process.standardError = errPipe

                        do {
                            try process.run()
                            _ = pipe.fileHandleForReading.readDataToEndOfFile()
                            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
                            process.waitUntilExit()

                            if process.terminationStatus == 0 {
                                continuation.resume(returning: "yt-dlp installed successfully via Homebrew. Ready to use.\nRun setup_ffmpeg too if not already installed (needed for format merging).")
                            } else {
                                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                                continuation.resume(returning: "Failed to install yt-dlp via Homebrew: \(err.prefix(300))\nInstall manually: brew install yt-dlp")
                            }
                        } catch {
                            continuation.resume(returning: "Failed to run Homebrew: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }

        return "yt-dlp not found and Homebrew not available.\nInstall manually: brew install yt-dlp\nOr: pip install yt-dlp\nGitHub: https://github.com/yt-dlp/yt-dlp"
    }

    private func getVersion(executable: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["--version"]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(returning: "unknown")
                }
            }
        }
    }
}
