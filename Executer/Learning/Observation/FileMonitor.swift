import Foundation
import AppKit

/// Monitors file system events in key directories to capture workflow patterns.
/// Stores ONLY patterns (extension + directory + app context), never filenames or content.
final class FileMonitor {
    static let shared = FileMonitor()

    /// Callback: invoked when a file event is detected.
    var onFileEvent: ((FileEvent) -> Void)?

    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileDescriptors: [Int32] = []
    private var isRunning = false

    /// Directories to monitor.
    private let monitoredPaths: [String] = [
        NSHomeDirectory() + "/Documents",
        NSHomeDirectory() + "/Desktop",
        NSHomeDirectory() + "/Downloads",
    ]

    struct FileEvent {
        let directory: String       // "Documents", "Desktop", "Downloads"
        let fileExtension: String   // "pptx", "swift", "pdf"
        let eventType: EventType
        let appName: String         // Frontmost app when event occurred
        let timestamp: Date

        enum EventType: String {
            case created
            case modified
            case deleted
            case renamed
        }
    }

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        for path in monitoredPaths {
            startMonitoring(path: path)
        }

        print("[FileMonitor] Started monitoring \(monitoredPaths.count) directories")
    }

    func stop() {
        isRunning = false
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        for fd in fileDescriptors {
            close(fd)
        }
        fileDescriptors.removeAll()
        print("[FileMonitor] Stopped")
    }

    private func startMonitoring(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            print("[FileMonitor] Failed to open \(path)")
            return
        }
        fileDescriptors.append(fd)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .global(qos: .utility)
        )

        let dirName = (path as NSString).lastPathComponent

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = source.data

            let eventType: FileEvent.EventType
            if flags.contains(.delete) {
                eventType = .deleted
            } else if flags.contains(.rename) {
                eventType = .renamed
            } else if flags.contains(.extend) {
                eventType = .created
            } else {
                eventType = .modified
            }

            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

            // We only report the directory and event type — never the specific filename
            let event = FileEvent(
                directory: dirName,
                fileExtension: "unknown", // Directory-level events don't have specific file info
                eventType: eventType,
                appName: appName,
                timestamp: Date()
            )

            self.onFileEvent?(event)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        sources.append(source)
    }
}
