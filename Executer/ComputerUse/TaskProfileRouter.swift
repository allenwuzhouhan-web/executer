import Foundation

/// Routes commands to specialized task profiles for optimized computer use.
enum TaskProfileRouter {

    /// A task profile with specialized system prompt, agent config, and tool restrictions.
    struct TaskProfile {
        let name: String
        let config: ComputerUseAgent.Config
    }

    /// Route a command to the best task profile, or nil for general computer use.
    static func route(command: String, currentApp: String? = nil) -> TaskProfile? {
        // Check IXL first (most specific)
        if IXLTaskProfile.detect(command: command) {
            return TaskProfile(name: "IXL", config: IXLTaskProfile.buildConfig())
        }

        // Check video editing
        if VideoEditProfile.detect(command: command) {
            return TaskProfile(name: "Video Edit", config: VideoEditProfile.buildConfig())
        }

        // Check photo editing
        if PhotoEditProfile.detect(command: command) {
            return TaskProfile(name: "Photo Edit", config: PhotoEditProfile.buildConfig())
        }

        // Check by current app context
        if let app = currentApp?.lowercased() {
            let photoApps = ["preview", "photoshop", "pixelmator", "photos", "gimp", "affinity photo"]
            if photoApps.contains(where: { app.contains($0) }) {
                return TaskProfile(name: "Photo Edit", config: PhotoEditProfile.buildConfig())
            }

            let videoApps = ["imovie", "final cut", "davinci", "premiere", "quicktime"]
            if videoApps.contains(where: { app.contains($0) }) {
                return TaskProfile(name: "Video Edit", config: VideoEditProfile.buildConfig())
            }
        }

        return nil
    }
}
