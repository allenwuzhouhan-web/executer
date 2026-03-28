import Cocoa

/// Full-screen transparent window that hosts the Core Animation glow comet.
class LaunchGlowWindow {
    private var window: NSWindow?
    private var glowLayer: LaunchGlowLayer?

    func show() {
        guard let screen = NSScreen.builtIn ?? NSScreen.main else { return }

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.isReleasedWhenClosed = false

        let containerView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = CGColor.clear

        let glow = LaunchGlowLayer()
        glow.frame = containerView.bounds
        glow.contentsScale = screen.backingScaleFactor
        containerView.layer?.addSublayer(glow)

        win.contentView = containerView
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.cornerRadius = 12
        win.contentView?.layer?.masksToBounds = true
        window = win
        glowLayer = glow

        win.orderFrontRegardless()

        // Start animation on next runloop tick (layer needs to be on screen)
        DispatchQueue.main.async {
            glow.startAnimation()
        }

        // Auto-remove after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.glowLayer = nil
        }
    }
}
