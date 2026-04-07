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

        // "play [song/query]" — dynamic: handles multiple phrasings
        if input.hasPrefix("play ") && !input.hasPrefix("play music") {
            let rest = String(input.dropFirst("play ".count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                let query = Self.buildMusicQuery(rest)
                let jsonArg = "{\"query\": \"\(escapeJSON(query))\"}"
                return try? await MusicPlaySongTool().execute(arguments: jsonArg)
            }
        }

        // "listen to [song/artist]"
        if input.hasPrefix("listen to ") {
            let rest = String(input.dropFirst("listen to ".count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                let query = Self.buildMusicQuery(rest)
                return try? await MusicPlaySongTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\"}")
            }
        }

        // "put on [song/genre]" / "throw on [song]"
        for prefix in ["put on ", "throw on "] as [String] {
            if input.hasPrefix(prefix) {
                let rest = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    let query = Self.buildMusicQuery(rest)
                    return try? await MusicPlaySongTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\"}")
                }
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

    // MARK: - Music Query Builder

    /// Extracts a clean search query from natural language music requests.
    /// "Shape of You by Ed Sheeran" → "Shape of You Ed Sheeran"
    /// "the album Thriller" → "Thriller"
    /// "my playlist Chill Vibes" → "Chill Vibes"
    /// "some jazz" → "jazz"
    private static func buildMusicQuery(_ raw: String) -> String {
        var text = raw

        // Strip "by" to flatten "Song by Artist" → "Song Artist" (tool handles both formats)
        if let byRange = text.range(of: " by ", options: .caseInsensitive) {
            text = String(text[text.startIndex..<byRange.lowerBound]) + " " +
                   String(text[byRange.upperBound...])
        }

        // Strip leading qualifiers — the tool searches all types anyway
        let stripPrefixes = ["the song ", "the album ", "the playlist ", "the artist ",
                             "my playlist ", "the ep ", "album ", "playlist ", "song ",
                             "some ", "a little ", "something by ", "something "]
        for prefix in stripPrefixes {
            if text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }

        // Strip trailing "on repeat" / "on shuffle"
        for suffix in [" on repeat", " on shuffle", " on loop"] {
            if text.lowercased().hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
            }
        }

        return text.trimmingCharacters(in: .whitespaces)
    }
}
