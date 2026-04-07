import Cocoa

/// Floating banner at the top of the screen showing "AI is in control" with a Stop button.
class AIControlBanner {
    static let shared = AIControlBanner()

    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var onStop: (() -> Void)?

    /// Show the banner.
    func show(message: String = "AI is in control") {
        DispatchQueue.main.async { [self] in
            if window == nil {
                setupWindow()
            }
            statusLabel?.stringValue = message
            window?.orderFront(nil)
        }
    }

    /// Hide the banner.
    func hide() {
        DispatchQueue.main.async { [self] in
            window?.orderOut(nil)
        }
    }

    /// Update the status text (e.g., "Clicking 'Submit'...").
    func updateStatus(_ status: String) {
        DispatchQueue.main.async { [self] in
            statusLabel?.stringValue = status
        }
    }

    /// Set callback for the Stop button.
    func setStopAction(_ action: @escaping () -> Void) {
        onStop = action
    }

    // MARK: - Setup

    private func setupWindow() {
        guard let screen = NSScreen.main else { return }

        let bannerWidth: CGFloat = 280
        let bannerHeight: CGFloat = 36

        let x = (screen.frame.width - bannerWidth) / 2
        let y = screen.frame.height - bannerHeight - 40 // Below menu bar

        let win = NSWindow(
            contentRect: NSRect(x: x, y: y, width: bannerWidth, height: bannerHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Container with rounded background
        let container = NSView(frame: NSRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight))
        container.wantsLayer = true
        container.layer?.cornerRadius = bannerHeight / 2
        container.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.92).cgColor

        // Purple dot indicator
        let dot = NSView(frame: NSRect(x: 12, y: (bannerHeight - 8) / 2, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0).cgColor
        container.addSubview(dot)

        // Pulsing animation on the dot
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.4
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        // Status label
        let label = NSTextField(frame: NSRect(x: 26, y: (bannerHeight - 16) / 2, width: bannerWidth - 86, height: 16))
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.stringValue = "AI is in control"
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)
        self.statusLabel = label

        // Stop button
        let stopButton = NSButton(frame: NSRect(x: bannerWidth - 56, y: (bannerHeight - 22) / 2, width: 48, height: 22))
        stopButton.bezelStyle = .roundRect
        stopButton.title = "Stop"
        stopButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        stopButton.contentTintColor = .systemRed
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        container.addSubview(stopButton)

        win.contentView = container
        self.window = win
    }

    @objc private func stopClicked() {
        AICursorManager.shared.stopAIControl()
        onStop?()
    }
}
