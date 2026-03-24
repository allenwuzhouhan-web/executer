import Foundation

extension LocalCommandRouter {

    func tryMusicCommand(_ input: String, words: Set<String>) async -> String? {
        if input == "pause" || input == "pause music" || input == "stop music" || matches(words, required: ["pause", "music"]) {
            return try? await MusicPauseTool().execute(arguments: "{}")
        }
        if input == "play music" || input == "resume music" || input == "resume" ||
           matches(words, required: ["resume", "music"]) || input == "unpause" || input == "unpause music" {
            return try? await MusicPlayTool().execute(arguments: "{}")
        }
        // "play [song name]" — route to MusicPlaySongTool for specific songs
        if input.hasPrefix("play ") && !input.hasPrefix("play music") {
            let songQuery = String(input.dropFirst("play ".count)).trimmingCharacters(in: .whitespaces)
            if !songQuery.isEmpty {
                let jsonArg = "{\"query\": \"\(escapeJSON(songQuery))\"}"
                return try? await MusicPlaySongTool().execute(arguments: jsonArg)
            }
        }
        if input == "next track" || input == "skip" || input == "next song" || input == "skip track" || input == "skip song" ||
           matches(words, required: ["next", "track"]) || matches(words, required: ["next", "song"]) ||
           input == "skip this" || input == "next" {
            return try? await MusicNextTool().execute(arguments: "{}")
        }
        if input == "previous track" || input == "previous song" || input == "last track" || input == "last song" ||
           matches(words, required: ["previous", "track"]) || matches(words, required: ["previous", "song"]) ||
           input == "go back" || input == "previous" {
            return try? await MusicPreviousTool().execute(arguments: "{}")
        }
        if input == "shuffle" || input == "shuffle on" || input == "shuffle off" || input == "toggle shuffle" ||
           matches(words, required: ["toggle", "shuffle"]) || matches(words, required: ["turn", "on", "shuffle"]) {
            return try? await MusicToggleShuffleTool().execute(arguments: "{}")
        }
        // "set music volume to X"
        if (input.contains("music volume") || input.contains("song volume")) {
            if let pct = extractPercentage(from: input) {
                return try? await MusicSetVolumeTool().execute(arguments: "{\"volume\": \(pct)}")
            }
        }

        return nil
    }
}
