import Foundation
import CoreGraphics
import AppKit

/// Fast in-memory screenshot capture via CGWindowListCreateImage.
/// 10-50x faster than spawning `screencapture` subprocess.
enum ScreenCapture {

    /// Capture the entire main display as a CGImage.
    static func captureMainDisplay() -> CGImage? {
        CGWindowListCreateImage(
            CGRect.null, // null = entire display
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
    }

    /// Capture the frontmost window only.
    static func captureFrontWindow() -> CGImage? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Find the first on-screen window belonging to the frontmost app
        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            return CGWindowListCreateImage(
                CGRect.null,
                .optionIncludingWindow,
                windowID,
                [.bestResolution, .boundsIgnoreFraming]
            )
        }

        return nil
    }

    /// Capture a specific screen region.
    static func captureRegion(_ rect: CGRect) -> CGImage? {
        CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        )
    }

    /// Convert CGImage to PNG data.
    static func toPNGData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Convert CGImage to base64-encoded PNG string, scaled to maxWidth.
    /// Used for sending screenshots to vision-capable LLMs.
    static func toBase64(_ image: CGImage, maxWidth: Int = 1024) -> String? {
        let originalWidth = image.width
        let originalHeight = image.height

        // Scale down if needed
        let scaledImage: CGImage
        if originalWidth > maxWidth {
            let scale = CGFloat(maxWidth) / CGFloat(originalWidth)
            let newWidth = Int(CGFloat(originalWidth) * scale)
            let newHeight = Int(CGFloat(originalHeight) * scale)

            guard let context = CGContext(
                data: nil, width: newWidth, height: newHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            guard let scaled = context.makeImage() else { return nil }
            scaledImage = scaled
        } else {
            scaledImage = image
        }

        guard let pngData = toPNGData(scaledImage) else { return nil }
        return pngData.base64EncodedString()
    }
}
