import Foundation
import CoreGraphics
import AppKit

/// Bezier-curve based mouse movement with configurable speed and easing.
/// Replaces the simple linear interpolation in MoveCursorTool.
class SmoothMouseDriver {
    static let shared = SmoothMouseDriver()

    // MARK: - Configuration

    struct MotionConfig {
        var durationMs: Int = 150
        var curve: MotionCurve = .easeInOut

        static let instant = MotionConfig(durationMs: 0, curve: .linear)
        static let fast = MotionConfig(durationMs: 80, curve: .easeInOut)
        static let normal = MotionConfig(durationMs: 150, curve: .easeInOut)
        static let slow = MotionConfig(durationMs: 300, curve: .easeOut)
    }

    enum MotionCurve {
        case linear
        case easeOut
        case easeInOut
        case bezier(cp1x: Double, cp1y: Double, cp2x: Double, cp2y: Double)
    }

    var defaultConfig = MotionConfig.normal

    // MARK: - Movement

    /// Move cursor to target with smooth animation. Posts mouseMoved events so apps track.
    func moveTo(_ target: CGPoint, config: MotionConfig? = nil) async throws {
        let cfg = config ?? defaultConfig

        // Get current position (NS coords → CG coords)
        let current = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let start = CGPoint(x: current.x, y: screenHeight - current.y)

        // Instant move
        if cfg.durationMs <= 0 {
            CGWarpMouseCursorPosition(target)
            postMouseMoved(at: target)
            return
        }

        // Calculate distance for dynamic step count
        let dx = target.x - start.x
        let dy = target.y - start.y
        let distance = sqrt(dx * dx + dy * dy)

        // Dynamic steps: more steps for longer distances
        let steps: Int
        if distance < 50 {
            steps = 8
        } else if distance < 200 {
            steps = 15
        } else if distance < 500 {
            steps = 20
        } else {
            steps = 30
        }

        let totalDuration = Double(cfg.durationMs) / 1000.0
        let stepDelay = totalDuration / Double(steps)

        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let easedT = applyEasing(t, curve: cfg.curve)

            let x = start.x + dx * CGFloat(easedT)
            let y = start.y + dy * CGFloat(easedT)
            let point = CGPoint(x: x, y: y)

            CGWarpMouseCursorPosition(point)
            postMouseMoved(at: point)

            // Feed trail point if AI cursor is active
            if AICursorManager.shared.isActive {
                AICursorManager.shared.addTrailPoint(point)
            }

            try await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000))
        }
    }

    /// Move cursor along a multi-point path.
    func moveAlongPath(_ points: [CGPoint], config: MotionConfig? = nil) async throws {
        for point in points {
            try await moveTo(point, config: config ?? MotionConfig(durationMs: 50, curve: .easeInOut))
        }
    }

    // MARK: - Easing Functions

    private func applyEasing(_ t: Double, curve: MotionCurve) -> Double {
        switch curve {
        case .linear:
            return t
        case .easeOut:
            // Cubic ease-out: fast start, slow end
            return 1.0 - pow(1.0 - t, 3)
        case .easeInOut:
            // Cubic ease-in-out: slow start, fast middle, slow end
            if t < 0.5 {
                return 4 * t * t * t
            } else {
                return 1 - pow(-2 * t + 2, 3) / 2
            }
        case .bezier(let cp1x, let cp1y, let cp2x, let cp2y):
            return cubicBezier(t: t, p1: cp1x, p2: cp1y, p3: cp2x, p4: cp2y)
        }
    }

    /// Evaluate cubic bezier curve at parameter t.
    /// Control points: (0,0), (p1,p2), (p3,p4), (1,1)
    private func cubicBezier(t: Double, p1: Double, p2: Double, p3: Double, p4: Double) -> Double {
        // Solve for the Y value at parameter t using the cubic bezier formula
        let u = 1.0 - t
        let tt = t * t
        let uu = u * u
        return 3 * uu * t * p2 + 3 * u * tt * p4 + tt * t
    }

    // MARK: - Helpers

    private func postMouseMoved(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Parse a speed string into a MotionConfig.
    static func configFromSpeed(_ speed: String?) -> MotionConfig {
        switch speed?.lowercased() {
        case "instant": return .instant
        case "fast": return .fast
        case "slow": return .slow
        case "normal", nil: return .normal
        default: return .normal
        }
    }
}
