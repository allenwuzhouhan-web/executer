import Cocoa

struct ScreenGeometry {
    /// Returns the CGRect of the notch region in screen coordinates, or nil if no notch.
    /// The rect covers the area just below/around the notch where the user would click.
    static func notchRect() -> CGRect? {
        guard let screen = NSScreen.builtIn else { return nil }

        // Check for notch: on notched MacBooks, the screen frame is taller than
        // the visible frame by more than just the menu bar (~24pt).
        // The notch adds ~14pt extra, making the top inset ~38pt.
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let topInset = frame.maxY - visibleFrame.maxY

        // A normal menu bar is ~24-25pt. With notch it's ~37-38pt.
        // If top inset is < 30, there's no notch.
        guard topInset > 30 else { return nil }

        // Try the proper API first (macOS 12+)
        if #available(macOS 12.0, *) {
            if let leftArea = screen.auxiliaryTopLeftArea,
               let rightArea = screen.auxiliaryTopRightArea {
                let notchX = frame.origin.x + leftArea.maxX
                let notchWidth = rightArea.minX - leftArea.maxX

                if notchWidth > 10 {
                    // Tight fit around the actual notch — no extra padding
                    return CGRect(
                        x: notchX,
                        y: frame.maxY - topInset,
                        width: notchWidth,
                        height: topInset
                    )
                }
            }
        }

        // Fallback: use known MacBook Pro notch dimensions
        // Notch bottom corners at CG coords (663, 32) to (848, 32) → width 185, height 32
        let notchWidth: CGFloat = 185
        let notchX = frame.midX - notchWidth / 2
        return CGRect(
            x: notchX,
            y: frame.maxY - topInset,
            width: notchWidth,
            height: topInset
        )
    }

    /// Returns true if the built-in display appears to have a notch.
    static var hasNotch: Bool {
        guard let screen = NSScreen.builtIn else { return false }
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        return topInset > 30
    }

    /// Debug: print notch geometry info
    static func debugPrint() {
        guard let screen = NSScreen.builtIn else {
            print("[Notch] No built-in screen found")
            return
        }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let topInset = frame.maxY - visible.maxY
        print("[Notch] Screen frame: \(frame)")
        print("[Notch] Visible frame: \(visible)")
        print("[Notch] Top inset: \(topInset)")
        print("[Notch] Has notch: \(topInset > 30)")

        if #available(macOS 12.0, *) {
            print("[Notch] auxiliaryTopLeftArea: \(String(describing: screen.auxiliaryTopLeftArea))")
            print("[Notch] auxiliaryTopRightArea: \(String(describing: screen.auxiliaryTopRightArea))")
            print("[Notch] safeAreaInsets: \(screen.safeAreaInsets)")
        }

        if let rect = notchRect() {
            print("[Notch] Click zone: \(rect)")
        } else {
            print("[Notch] No notch rect computed")
        }
    }
}

extension NSScreen {
    /// Returns the built-in display (MacBook's own screen), or nil.
    static var builtIn: NSScreen? {
        NSScreen.screens.first { screen in
            let description = screen.deviceDescription
            guard let screenNumber = description[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(screenNumber) != 0
        }
    }
}
