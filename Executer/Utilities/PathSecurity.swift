import Foundation

/// Validates file paths to prevent access to sensitive system locations.
enum PathSecurity {

    static let maxFileSize: UInt64 = 2_000_000 // 2MB

    private static let blockedPrefixes: [String] = [
        "/System/",
        "/usr/",
        "/etc/",
        "/private/var/",
        "/sbin/",
        "/bin/",
    ]

    private static let blockedHomeDirs: [String] = [
        ".ssh",
        ".aws",
        ".gnupg",
        ".config/gh",
        "Library/Keychains",
    ]

    /// Returns true if the path is safe to read/write.
    static func isAllowed(_ path: String) -> Bool {
        // Reject path traversal
        let normalized = (path as NSString).standardizingPath
        if normalized.contains("..") {
            return false
        }

        // Block system directories
        for prefix in blockedPrefixes {
            if normalized.hasPrefix(prefix) {
                return false
            }
        }

        // Block sensitive home directories
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in blockedHomeDirs {
            let sensitive = (home as NSString).appendingPathComponent(dir)
            if normalized.hasPrefix(sensitive) {
                return false
            }
        }

        return true
    }

    /// Returns true if the file appears to be binary (contains null bytes in first 8KB).
    static func isBinary(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: 8192)
        return data.contains(0x00)
    }

    /// Validates a path and throws if blocked.
    static func validate(_ path: String) throws {
        guard isAllowed(path) else {
            throw ExecuterError.permissionDenied("Access to '\(path)' is not allowed.")
        }
    }
}
