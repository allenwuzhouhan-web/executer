import Foundation
import AppKit

/// Monitors clipboard changes and feeds cross-app flow patterns into the Learning pipeline.
/// Does NOT store clipboard content — only tracks: sourceApp, contentType, contentLength.
final class ClipboardObserver {
    static let shared = ClipboardObserver()

    /// Callback: invoked when a clipboard flow pattern is detected.
    var onClipboardFlow: ((ClipboardFlow) -> Void)?

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var lastCopyApp: String?
    private var lastCopyTime: Date?
    private var isRunning = false

    struct ClipboardFlow {
        let sourceApp: String       // App where content was copied
        let destinationApp: String  // App where content was pasted (inferred from next focus)
        let contentType: ContentType
        let contentLength: Int      // Character count for text, pixel count for images
        let timestamp: Date

        enum ContentType: String {
            case text
            case image
            case url
            case file
            case other
        }
    }

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastChangeCount = NSPasteboard.general.changeCount

        // Must schedule on main RunLoop — start() may be called from a Task/actor context
        // whose thread has no active RunLoop, causing the timer to silently never fire.
        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.checkClipboard()
            }
        }

        print("[ClipboardObserver] Started monitoring clipboard flows")
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        print("[ClipboardObserver] Stopped")
    }

    private func checkClipboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        let pasteboard = NSPasteboard.general
        let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        // Determine content type and length (without reading actual content)
        let contentType: ClipboardFlow.ContentType
        let contentLength: Int

        if let types = pasteboard.types {
            if types.contains(.string) {
                contentType = .text
                contentLength = pasteboard.string(forType: .string)?.count ?? 0
            } else if types.contains(.tiff) || types.contains(.png) {
                contentType = .image
                contentLength = pasteboard.data(forType: .tiff)?.count ?? 0
            } else if types.contains(.URL) || types.contains(.fileURL) {
                contentType = types.contains(.fileURL) ? .file : .url
                contentLength = pasteboard.string(forType: .string)?.count ?? 0
            } else {
                contentType = .other
                contentLength = 0
            }
        } else {
            contentType = .other
            contentLength = 0
        }

        // If we had a previous copy, and this is a different app, record a flow
        if let sourceApp = lastCopyApp, sourceApp != currentApp,
           let copyTime = lastCopyTime,
           Date().timeIntervalSince(copyTime) < 300 { // Within 5 minutes
            let flow = ClipboardFlow(
                sourceApp: sourceApp,
                destinationApp: currentApp,
                contentType: contentType,
                contentLength: contentLength,
                timestamp: Date()
            )
            onClipboardFlow?(flow)
        }

        // Record this as the latest copy event
        lastCopyApp = currentApp
        lastCopyTime = Date()
    }
}
