import Cocoa
import SwiftUI

/// A floating window that hosts the SwiftUI input bar.
/// Uses NSWindow (not NSPanel) for reliable activation and keyboard focus.
class InputBarPanel: NSWindow {
    private let appState: AppState
    private var escapeMonitor: Any?

    init(appState: AppState) {
        self.appState = appState

        // Use a safe default frame — will be repositioned in showBar()
        super.init(
            contentRect: CGRect(x: 100, y: 100, width: 340, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .popUpMenu  // Above everything including menu bar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isMovableByWindowBackground = false

        let hostingView = NSHostingView(rootView:
            InputBarView()
                .environmentObject(appState)
        )
        hostingView.frame = CGRect(x: 0, y: 0, width: 340, height: 200)
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView

        print("[InputBarPanel] Created")
    }

    func showBar() {
        print("[InputBarPanel] showBar()")

        // Local event monitor catches escape even when the field editor swallows it
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { // Escape
                    self?.appState.hideInputBar()
                    return nil // swallow the event
                }
                return event
            }
        }

        // Get screen — try built-in first, then main, then any
        let screen = NSScreen.builtIn ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.frame else {
            print("[InputBarPanel] ERROR: No screen found!")
            return
        }

        // Position: centered horizontally, just below the notch
        let panelWidth: CGFloat = 300
        let panelHeight: CGFloat = 360
        let panelX = screenFrame.midX - panelWidth / 2
        let panelY = screenFrame.maxY - panelHeight - 44
        setFrame(CGRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight), display: true)

        alphaValue = 1.0

        // Activate app — use modern API with fallback
        NSApp.activate()

        // Show the window
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)

        print("[InputBarPanel] Frame: \(frame), visible: \(isVisible), key: \(isKeyWindow)")

        // Focus the text field after SwiftUI has laid out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            NSApp.activate()
            self.makeKeyAndOrderFront(nil)
            self.focusTextField(in: self.contentView ?? NSView())
            print("[InputBarPanel] After focus attempt — key: \(self.isKeyWindow)")
        }
    }

    func hideBar() {
        print("[InputBarPanel] hideBar()")
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        orderOut(nil)
    }

    private func focusTextField(in view: NSView) {
        for subview in view.subviews {
            if let textField = subview as? NSTextField, textField.isEditable {
                makeFirstResponder(textField)
                print("[InputBarPanel] Focused text field: \(textField)")
                return
            }
            focusTextField(in: subview)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            appState.hideInputBar()
        } else {
            super.keyDown(with: event)
        }
    }
}
