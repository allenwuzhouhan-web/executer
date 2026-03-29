import Foundation

/// Immutable model identification for this build of Executer.
/// Cannot be changed at runtime. Baked into the binary.
enum AppModel {
    /// Model number — unique identifier for this build.
    static let modelNumber = "EX-2026.3.29-PR"

    /// Build type classification.
    static let buildType: BuildType = .prerelease

    /// Version from Info.plist.
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Build number from Info.plist.
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    enum BuildType: String {
        case prerelease = "Pre-Release"
        case beta = "Beta"
        case release = "Release"
    }

    /// Full display string for UI.
    static var displayString: String {
        "Executer \(modelNumber) (\(buildType.rawValue))"
    }

    /// Short display for compact UI.
    static var shortString: String {
        "v\(version) \(buildType.rawValue)"
    }

    /// Whether this is a pre-release build.
    static var isPrerelease: Bool {
        buildType == .prerelease || buildType == .beta
    }
}
