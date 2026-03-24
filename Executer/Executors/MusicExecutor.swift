import Foundation

struct MusicPlayTool: ToolDefinition {
    let name = "music_play"
    let description = "Resume playing the current track in Apple Music, or start playing if paused"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let script = """
        tell application "Music"
            play
            delay 0.5
            if player state is playing then
                return "Now playing: " & name of current track & " by " & artist of current track
            else
                return "Playing music."
            end if
        end tell
        """
        return try AppleScriptRunner.runThrowing(script)
    }
}

struct MusicPauseTool: ToolDefinition {
    let name = "music_pause"
    let description = "Pause the currently playing music"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        try AppleScriptRunner.runThrowing("tell application \"Music\" to pause")
        return "Music paused."
    }
}

struct MusicNextTool: ToolDefinition {
    let name = "music_next"
    let description = "Skip to the next track"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        try AppleScriptRunner.runThrowing("tell application \"Music\" to next track")
        return "Skipped to next track."
    }
}

struct MusicPreviousTool: ToolDefinition {
    let name = "music_previous"
    let description = "Go back to the previous track"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        try AppleScriptRunner.runThrowing("tell application \"Music\" to previous track")
        return "Went to previous track."
    }
}

struct MusicCatalogSearchTool: ToolDefinition {
    let name = "music_search"
    let description = "Search Apple Music for songs, artists, or albums. Searches your local library first; if nothing is found, opens the full Apple Music catalog search in the Music app."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Search query (song name, artist, album, or combination like 'Blinding Lights The Weeknd')"),
            "limit": JSONSchema.integer(description: "Max results to return from library (default 5)", minimum: 1, maximum: 15),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let limit = optionalInt("limit", from: args) ?? 5
        let safeQuery = AppleScriptRunner.escape(query)

        // Tier 1: Fast library search
        let libraryScript = """
        tell application "Music"
            set matchedTracks to (search playlist "Library" for "\(safeQuery)")
            set trackCount to count of matchedTracks
            if trackCount = 0 then return "NO_RESULTS"
            set maxCount to \(limit)
            if trackCount < maxCount then set maxCount to trackCount
            set output to ""
            repeat with i from 1 to maxCount
                set t to item i of matchedTracks
                set output to output & i & ". " & (name of t) & " — " & (artist of t) & " [" & (album of t) & "]" & linefeed
            end repeat
            return output
        end tell
        """
        let libraryResult = try AppleScriptRunner.runThrowing(libraryScript)
        if libraryResult != "NO_RESULTS" {
            return "Library results for '\(query)':\n\(libraryResult)"
        }

        // Tier 2: Search iTunes catalog API (free, no key needed)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=\(limit)")!

        let (data, _) = try await URLSession.shared.data(from: searchURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              !results.isEmpty else {
            return "No results found for '\(query)' on Apple Music."
        }

        var output = "Apple Music catalog results for '\(query)':\n"
        for (i, track) in results.enumerated() {
            let trackName = track["trackName"] as? String ?? "Unknown"
            let artistName = track["artistName"] as? String ?? "Unknown"
            let albumName = track["collectionName"] as? String ?? ""
            output += "\(i + 1). \(trackName) — \(artistName)"
            if !albumName.isEmpty { output += " [\(albumName)]" }
            output += "\n"
        }
        output += "\nUse `music_play_song` with any of these to play it."
        return output
    }
}

struct MusicPlaySongTool: ToolDefinition {
    let name = "music_play_song"
    let description = "Search for and immediately play a song in Apple Music. Tries your library first (instant), then searches the full Apple Music streaming catalog and plays the top result."
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Song name, optionally with artist (e.g. 'Blinding Lights The Weeknd', 'bohemian rhapsody')"),
        ], required: ["query"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let safeQuery = AppleScriptRunner.escape(query)

        // Tier 1: Try library (fast, no UI disruption)
        let libraryScript = """
        tell application "Music"
            set matchedTracks to (search playlist "Library" for "\(safeQuery)")
            if (count of matchedTracks) > 0 then
                play item 1 of matchedTracks
                return "LIBRARY:" & name of current track & " by " & artist of current track
            end if
            return "NO_RESULTS"
        end tell
        """
        let libraryResult = try AppleScriptRunner.runThrowing(libraryScript)
        if libraryResult.hasPrefix("LIBRARY:") {
            let info = String(libraryResult.dropFirst("LIBRARY:".count))
            return "Now playing: \(info)"
        }

        // Tier 2: Use iTunes Search API (free, no key) to find the track, then play it directly
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=1")!

        let (data, _) = try await URLSession.shared.data(from: searchURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let trackURL = first["trackViewUrl"] as? String,
              let trackName = first["trackName"] as? String,
              let artistName = first["artistName"] as? String else {
            return "No results found for '\(query)' on Apple Music."
        }

        // Open the track URL directly in Music — this navigates to the exact song
        let playScript = """
        tell application "Music"
            open location "\(trackURL)"
        end tell

        delay 3.0

        -- The track page should be open — press play
        tell application "System Events"
            tell process "Music"
                set frontmost to true
                delay 0.3
                -- Space to play
                keystroke space
            end tell
        end tell

        delay 1.5

        tell application "Music"
            if player state is playing then
                return "PLAYING"
            else
                return "OPENED"
            end if
        end tell
        """
        let playResult = try AppleScriptRunner.runThrowing(playScript)
        if playResult == "PLAYING" {
            return "Now playing: \(trackName) by \(artistName)"
        }
        return "Opened \(trackName) by \(artistName) in Apple Music. Press play in the app."
    }
}

struct MusicGetCurrentTool: ToolDefinition {
    let name = "music_get_current"
    let description = "Get information about the currently playing track"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        let script = """
        tell application "Music"
            if player state is playing then
                return name of current track & " by " & artist of current track & " from " & album of current track
            else
                return "Nothing is currently playing."
            end if
        end tell
        """
        return try AppleScriptRunner.runThrowing(script)
    }
}

struct MusicSetVolumeTool: ToolDefinition {
    let name = "music_set_volume"
    let description = "Set the Apple Music volume (0-100)"
    var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "volume": JSONSchema.integer(description: "Volume level from 0 to 100", minimum: 0, maximum: 100)
        ], required: ["volume"])
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let vol = optionalInt("volume", from: args) else {
            throw ExecuterError.invalidArguments("volume is required")
        }
        try AppleScriptRunner.runThrowing("tell application \"Music\" to set sound volume to \(vol)")
        return "Music volume set to \(vol)%."
    }
}

struct MusicToggleShuffleTool: ToolDefinition {
    let name = "music_toggle_shuffle"
    let description = "Toggle shuffle mode on/off in Apple Music"
    var parameters: [String: Any] { JSONSchema.object(properties: [:]) }

    func execute(arguments: String) async throws -> String {
        try AppleScriptRunner.runThrowing("tell application \"Music\" to set shuffle enabled to (not shuffle enabled)")
        let state = AppleScriptRunner.run("tell application \"Music\" to get shuffle enabled") ?? "unknown"
        return "Shuffle is now \(state == "true" ? "on" : "off")."
    }
}
