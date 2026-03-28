import SwiftUI
import AppKit

class WelcomeWindowController {
    private var window: NSWindow?

    func show(completion: @escaping () -> Void) {
        let view = WelcomeView(onComplete: { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self?.window?.animator().alphaValue = 0
            } completionHandler: {
                self?.window?.close()
                self?.window = nil
                UserDefaults.standard.set(true, forKey: "has_completed_onboarding")
                completion()
            }
        })

        let hostingView = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.center()
        win.contentView = hostingView
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.backgroundColor = .windowBackgroundColor

        // Rounded corners
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.cornerRadius = 16
        win.contentView?.layer?.masksToBounds = true

        // Fade-in entrance
        win.alphaValue = 0
        win.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            win.animator().alphaValue = 1
        }

        self.window = win
    }
}
