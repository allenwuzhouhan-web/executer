import Foundation

extension LocalCommandRouter {

    func tryFileCommand(_ input: String, words: Set<String>) async -> String? {

        // --- Find files ---
        // "find [x]" / "find files named [x]" / "search for file [x]" / "where is [x]"
        // "find [x] in documents" / "find [x] in downloads" / "find [x] on desktop"
        if input.hasPrefix("find files named ") {
            let query = String(input.dropFirst("find files named ".count)).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                let (searchQuery, directory) = splitFindQueryAndLocation(query)
                return await executeFindFiles(query: searchQuery, directory: directory)
            }
        }
        if input.hasPrefix("search for file ") || input.hasPrefix("search for files ") {
            let prefix = input.hasPrefix("search for file ") ? "search for file " : "search for files "
            let query = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                let (searchQuery, directory) = splitFindQueryAndLocation(query)
                return await executeFindFiles(query: searchQuery, directory: directory)
            }
        }
        if input.hasPrefix("where is ") {
            let query = String(input.dropFirst("where is ".count)).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                let (searchQuery, directory) = splitFindQueryAndLocation(query)
                return await executeFindFiles(query: searchQuery, directory: directory)
            }
        }
        if input.hasPrefix("find ") && !input.hasPrefix("find and ") {
            let query = String(input.dropFirst("find ".count)).trimmingCharacters(in: .whitespaces)
            // Avoid capturing "find files named" (already handled) or ambiguous phrases
            if !query.isEmpty && !query.hasPrefix("files named") && !query.hasPrefix("file ") {
                let (searchQuery, directory) = splitFindQueryAndLocation(query)
                return await executeFindFiles(query: searchQuery, directory: directory)
            }
        }
        // "locate [x]"
        if input.hasPrefix("locate ") {
            let query = String(input.dropFirst("locate ".count)).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                let (searchQuery, directory) = splitFindQueryAndLocation(query)
                return await executeFindFiles(query: searchQuery, directory: directory)
            }
        }

        // --- Open file (only when it looks like a file with an extension) ---
        // "open report.pdf" / "open ~/Documents/notes.txt"
        if input.hasPrefix("open ") {
            let target = String(input.dropFirst("open ".count)).trimmingCharacters(in: .whitespaces)
            if looksLikeFilePath(target) {
                let path = resolveFilePath(target)
                return try? await OpenFileTool().execute(arguments: "{\"path\": \"\(escapeJSON(path))\"}")
            }
        }

        // --- Reveal in Finder ---
        // "show in finder [path]" / "reveal [path] in finder" / "show [x] in finder"
        if input.hasPrefix("show in finder ") {
            let path = String(input.dropFirst("show in finder ".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await RevealInFinderTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }
        if input.hasPrefix("reveal ") && input.hasSuffix(" in finder") {
            let path = String(input.dropFirst("reveal ".count).dropLast(" in finder".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await RevealInFinderTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }
        if input.hasPrefix("show ") && input.hasSuffix(" in finder") && !input.hasPrefix("show in finder") {
            let path = String(input.dropFirst("show ".count).dropLast(" in finder".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await RevealInFinderTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }
        if input.hasPrefix("reveal in finder ") {
            let path = String(input.dropFirst("reveal in finder ".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await RevealInFinderTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }

        // --- Trash / delete file ---
        // "trash [filename]" / "delete [filename]" / "move [x] to trash"
        if input.hasPrefix("trash ") {
            let path = String(input.dropFirst("trash ".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await TrashFileTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }
        if input.hasPrefix("delete ") {
            let path = String(input.dropFirst("delete ".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty && looksLikeFilePath(path) {
                let resolved = resolveFilePath(path)
                return try? await TrashFileTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }
        if input.hasPrefix("move ") && input.hasSuffix(" to trash") {
            let path = String(input.dropFirst("move ".count).dropLast(" to trash".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await TrashFileTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }

        // --- Create folder ---
        // "create folder [name]" / "new folder [name]" / "make folder [name]" / "mkdir [name]"
        // "create folder [name] in [location]" / "new folder [name] on desktop"
        let folderPrefixes = ["create folder ", "new folder ", "make folder ", "mkdir ", "create directory ", "make directory "]
        for prefix in folderPrefixes {
            if input.hasPrefix(prefix) {
                let rest = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    let (name, location) = splitFolderNameAndLocation(rest)
                    let basePath = location != nil ? resolveLocationPath(location!) : "~"
                    let fullPath = basePath.hasSuffix("/") ? "\(basePath)\(name)" : "\(basePath)/\(name)"
                    return try? await CreateFolderTool().execute(arguments: "{\"path\": \"\(escapeJSON(fullPath))\"}")
                }
            }
        }

        // --- List directory / downloads / desktop ---
        // "list files" / "list downloads" / "show downloads" / "what's in downloads"
        // "what's on my desktop" / "list desktop" / "show desktop files"
        if input == "list files" || input == "list directory" || input == "ls" {
            return try? await ListDirectoryTool().execute(arguments: "{}")
        }
        if input == "list downloads" || input == "show downloads" || input == "show download files" ||
           input == "what's in downloads" || input == "whats in downloads" ||
           input == "what's in my downloads" || input == "whats in my downloads" ||
           matches(words, required: ["list", "downloads"]) || matches(words, required: ["show", "downloads"]) {
            return try? await ListDirectoryTool().execute(arguments: "{\"path\": \"~/Downloads\"}")
        }
        if input == "list desktop" || input == "show desktop files" || input == "desktop files" ||
           input == "what's on my desktop" || input == "whats on my desktop" ||
           input == "what's on desktop" || input == "whats on desktop" ||
           matches(words, required: ["list", "desktop"]) {
            return try? await ListDirectoryTool().execute(arguments: "{\"path\": \"~/Desktop\"}")
        }
        if input == "list documents" || input == "show documents" ||
           input == "what's in documents" || input == "whats in documents" ||
           input == "what's in my documents" || input == "whats in my documents" ||
           matches(words, required: ["list", "documents"]) || matches(words, required: ["show", "documents"]) {
            return try? await ListDirectoryTool().execute(arguments: "{\"path\": \"~/Documents\"}")
        }
        // "list [path]" / "ls [path]"
        if input.hasPrefix("list ") && !input.contains("download") && !input.contains("desktop") &&
           !input.contains("document") && !input.contains("window") && !input.contains("files") {
            let path = String(input.dropFirst("list ".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await ListDirectoryTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }
        if input.hasPrefix("ls ") {
            let path = String(input.dropFirst("ls ".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await ListDirectoryTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }

        // --- Downloads shortcut ---
        // "downloads" / "open downloads" / "go to downloads"
        if input == "downloads" || input == "open downloads" || input == "go to downloads" ||
           input == "open my downloads" {
            return try? await GetDownloadsPathTool().execute(arguments: "{}")
        }

        // --- Finder path ---
        // "what's the current finder path" / "where am i in finder" / "current folder"
        if input == "current folder" || input == "current directory" || input == "pwd" ||
           input == "where am i in finder" || input == "what's the current finder path" ||
           input == "whats the current finder path" || input == "current finder path" ||
           input == "finder path" || input == "current path" ||
           matches(words, required: ["current", "finder", "path"]) {
            return try? await GetFinderWindowPathTool().execute(arguments: "{}")
        }

        // --- File info ---
        // "file info [path]" / "get info on [file]" / "how big is [file]"
        if input.hasPrefix("file info ") {
            let path = String(input.dropFirst("file info ".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await GetFileInfoTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }
        if input.hasPrefix("get info on ") || input.hasPrefix("get info for ") {
            let prefix = input.hasPrefix("get info on ") ? "get info on " : "get info for "
            let path = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await GetFileInfoTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }
        if input.hasPrefix("how big is ") {
            let path = String(input.dropFirst("how big is ".count)).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                let resolved = resolveFilePath(path)
                return try? await GetFileInfoTool().execute(arguments: "{\"path\": \"\(escapeJSON(resolved))\"}")
            }
        }

        return nil
    }

    // MARK: - Power / System commands

    func trySystemCommand(_ input: String, words: Set<String>) async -> String? {

        // --- Restart ---
        if input == "restart" || input == "restart my mac" || input == "restart mac" ||
           input == "restart computer" || input == "restart my computer" || input == "reboot" ||
           input == "reboot my mac" || input == "reboot mac" ||
           matches(words, required: ["restart", "mac"]) || matches(words, required: ["restart", "computer"]) ||
           matches(words, required: ["reboot", "mac"]) {
            return try? await RestartTool().execute(arguments: "{}")
        }

        // --- Shut down ---
        if input == "shut down" || input == "shutdown" || input == "shut down my mac" ||
           input == "shutdown my mac" || input == "turn off" || input == "power off" ||
           input == "turn off my mac" || input == "power off my mac" ||
           input == "shut down mac" || input == "turn off mac" || input == "shut down computer" ||
           matches(words, required: ["shut", "down", "mac"]) || matches(words, required: ["shut", "down", "computer"]) ||
           matches(words, required: ["power", "off"]) || matches(words, required: ["turn", "off", "mac"]) ||
           matches(words, required: ["turn", "off", "computer"]) {
            return try? await ShutdownTool().execute(arguments: "{}")
        }

        // --- Log out ---
        if input == "log out" || input == "logout" || input == "sign out" || input == "signout" ||
           input == "log out of my mac" || input == "log me out" || input == "sign me out" ||
           matches(words, required: ["log", "out"]) || matches(words, required: ["sign", "out"]) {
            return try? await LogOutTool().execute(arguments: "{}")
        }

        // --- Prevent sleep / caffeinate ---
        if input == "caffeinate" || input == "prevent sleep" || input == "keep awake" ||
           input == "don't sleep" || input == "dont sleep" || input == "stay awake" ||
           input == "keep my mac awake" || input == "no sleep" || input == "stop sleeping" ||
           input == "keep screen on" || input == "keep awake mode" ||
           matches(words, required: ["prevent", "sleep"]) || matches(words, required: ["keep", "awake"]) ||
           matches(words, required: ["stay", "awake"]) || matches(words, required: ["don't", "sleep"]) {
            return try? await PreventSleepTool().execute(arguments: "{}")
        }

        // --- Open System Settings (generic) ---
        if input == "open settings" || input == "open system settings" || input == "system settings" ||
           input == "system preferences" || input == "open system preferences" || input == "preferences" ||
           input == "open preferences" || input == "settings" ||
           matches(words, required: ["system", "settings"]) || matches(words, required: ["system", "preferences"]) {
            return try? await OpenSystemPreferencesTool().execute(arguments: "{}")
        }

        // --- Open System Settings (specific pane) — dynamic ---
        // Matches "[X] settings" / "open [X] settings" / "open [X]" (when X is a settings-like word)
        // Small alias map for non-obvious names only; everything else passed as-is
        if input.hasSuffix(" settings") || input.hasSuffix(" preferences") {
            let suffix = input.hasSuffix(" settings") ? " settings" : " preferences"
            var paneName = String(input.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if paneName.hasPrefix("open ") { paneName = String(paneName.dropFirst("open ".count)) }
            if paneName.hasPrefix("system ") { paneName = String(paneName.dropFirst("system ".count)) }
            if !paneName.isEmpty {
                let resolved = Self.resolveSettingsPane(paneName)
                return try? await OpenSystemPreferencesTool().execute(arguments: "{\"pane\": \"\(escapeJSON(resolved))\"}")
            }
        }
        // "open [X]" where X looks like a settings pane (not an app or file)
        if input.hasPrefix("open ") {
            let target = String(input.dropFirst("open ".count)).trimmingCharacters(in: .whitespaces)
            if Self.settingsLikeWords.contains(target) || Self.settingsPaneAliases[target] != nil {
                let resolved = Self.resolveSettingsPane(target)
                return try? await OpenSystemPreferencesTool().execute(arguments: "{\"pane\": \"\(escapeJSON(resolved))\"}")
            }
        }

        return nil
    }

    // MARK: - File path helpers

    // Cached regex: matches a dot followed by 1-5 alphanumeric chars at end of string or before whitespace
    private static let fileExtensionPattern = try! NSRegularExpression(pattern: #"\.\w{1,5}$"#)

    /// Checks if a string looks like a file path (has an extension or path separators).
    /// Dynamic: any ".xyz" suffix counts as a file extension — no hardcoded list.
    private func looksLikeFilePath(_ target: String) -> Bool {
        // Contains path separator
        if target.contains("/") || target.hasPrefix("~") { return true }
        // Has any file extension (dot + 1-5 alphanumeric chars at end)
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
        if Self.fileExtensionPattern.firstMatch(in: trimmed, range: nsRange) != nil {
            // Exclude things that look like domains (already handled by web matcher)
            if trimmed.contains(" ") { return true } // "report.pdf" (no spaces in domains)
            // Single word with extension: check it's not a bare domain
            let ext = (trimmed as NSString).pathExtension.lowercased()
            let domainTLDs: Set<String> = ["com", "org", "net", "io", "co", "ai", "app", "dev", "tv"]
            return !domainTLDs.contains(ext)
        }
        return false
    }

    /// Resolves well-known location names to paths and expands ~.
    private func resolveFilePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("~") || trimmed.hasPrefix("/") {
            return trimmed
        }
        // Known location shortcuts
        let lower = trimmed.lowercased()
        if lower == "desktop" { return "~/Desktop" }
        if lower == "downloads" { return "~/Downloads" }
        if lower == "documents" { return "~/Documents" }
        if lower == "home" { return "~" }
        if lower == "applications" { return "/Applications" }
        // If it looks like just a filename, return as-is (tool will handle)
        return trimmed
    }

    /// Resolves a location name ("desktop", "documents", "downloads") to a path.
    private func resolveLocationPath(_ location: String) -> String {
        let lower = location.lowercased().trimmingCharacters(in: .whitespaces)
        switch lower {
        case "desktop", "the desktop", "my desktop":
            return "~/Desktop"
        case "downloads", "the downloads", "my downloads", "download", "the download folder":
            return "~/Downloads"
        case "documents", "the documents", "my documents", "document", "the documents folder":
            return "~/Documents"
        case "home", "home folder", "my home", "home directory":
            return "~"
        case "applications", "the applications folder":
            return "/Applications"
        default:
            return "~/\(location)"
        }
    }

    /// Splits a find query that may contain "in [location]" or "on [location]".
    /// Returns (query, directory?) where directory is nil if no location found.
    private func splitFindQueryAndLocation(_ text: String) -> (String, String?) {
        // "report in documents" → ("report", "~/Documents")
        // "notes on desktop" → ("notes", "~/Desktop")
        for prep in [" in ", " on ", " inside ", " under "] {
            if let range = text.range(of: prep, options: .backwards) {
                let query = String(text[text.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let location = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !query.isEmpty && !location.isEmpty {
                    let resolved = resolveLocationPath(location)
                    return (query, resolved)
                }
            }
        }
        return (text, nil)
    }

    /// Splits "ProjectX in documents" / "ProjectX on desktop" into (name, location).
    private func splitFolderNameAndLocation(_ text: String) -> (String, String?) {
        for prep in [" in ", " on ", " inside ", " under "] {
            if let range = text.range(of: prep, options: .backwards) {
                let name = String(text[text.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let location = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !location.isEmpty {
                    return (name, location)
                }
            }
        }
        return (text, nil)
    }

    /// Executes FindFilesTool with optional directory.
    private func executeFindFiles(query: String, directory: String?) async -> String? {
        if let dir = directory {
            return try? await FindFilesTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\", \"directory\": \"\(escapeJSON(dir))\"}")
        } else {
            return try? await FindFilesTool().execute(arguments: "{\"query\": \"\(escapeJSON(query))\"}")
        }
    }

    // MARK: - Settings Pane Resolution

    /// Words that are settings-like when used with "open [X]" — not app names
    private static let settingsLikeWords: Set<String> = [
        "wifi", "wi-fi", "bluetooth", "sound", "audio", "display", "displays",
        "battery", "notifications", "keyboard", "trackpad", "mouse",
        "general", "privacy", "network", "appearance", "wallpaper",
        "screen saver", "screensaver", "lock screen", "focus", "accessibility",
        "siri", "spotlight", "time machine", "users", "accounts",
        "passwords", "internet accounts", "extensions", "sharing",
        "printers", "printers & scanners", "storage", "desktop & dock",
        "control center", "login items",
    ]

    /// Aliases for non-obvious pane names only
    private static let settingsPaneAliases: [String: String] = [
        "wifi": "Wi-Fi", "wi-fi": "Wi-Fi",
        "audio": "Sound",
        "screen": "Displays", "monitor": "Displays",
        "mouse": "Mouse",
        "privacy": "Privacy & Security",
        "wallpaper": "Wallpaper",
        "screensaver": "Screen Saver", "screen saver": "Screen Saver",
        "dock": "Desktop & Dock",
        "users": "Users & Groups", "accounts": "Users & Groups",
        "sharing": "General",
        "printers": "Printers & Scanners",
        "storage": "General",
        "login items": "General",
    ]

    /// Resolves a user-typed pane name to what System Settings expects.
    /// Known aliases get mapped; everything else gets title-cased and passed through.
    private static func resolveSettingsPane(_ input: String) -> String {
        let lower = input.lowercased()
        if let alias = settingsPaneAliases[lower] { return alias }
        // Title-case: "bluetooth" → "Bluetooth", "lock screen" → "Lock Screen"
        return lower.split(separator: " ").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
