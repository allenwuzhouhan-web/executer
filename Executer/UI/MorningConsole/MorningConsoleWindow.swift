import AppKit
import SwiftUI

/// NSWindow wrapper for the Morning Console. Auto-shows on first input after sleep/overnight session.
class MorningConsoleWindow {
    private var window: NSWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let consoleView = MorningConsoleView(onDismiss: { [weak self] in
            self?.close()
        })

        let hostingView = NSHostingView(rootView: consoleView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 500)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Morning Briefing"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)

        self.window = window
        print("[MorningConsole] Window shown")
    }

    func close() {
        window?.close()
        window = nil
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let morningConsoleReady = Notification.Name("morningConsoleReady")
}
