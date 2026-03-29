import Cocoa
import SwiftUI

/// Fullscreen security lockdown window. Shows when integrity check fails.
/// Cannot be dismissed — user must quit and reinstall.
class LockdownWindow {

    private var window: NSWindow?
    private var alertTimer: Timer?

    /// Show the lockdown screen with alert sound.
    func show(reason: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver + 1  // Above everything
        win.backgroundColor = .clear
        win.isOpaque = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.isReleasedWhenClosed = false

        let lockdownView = NSHostingView(rootView: LockdownContentView(reason: reason))
        lockdownView.frame = CGRect(origin: .zero, size: screen.frame.size)
        win.contentView = lockdownView

        window = win
        win.makeKeyAndOrderFront(nil)

        // Play alert sound immediately and every 5 seconds
        playAlertSound()
        alertTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.playAlertSound()
        }

        print("[LOCKDOWN] Security lockdown activated: \(reason)")
    }

    private func playAlertSound() {
        NSSound(named: "Basso")?.play()
    }

    func dismiss() {
        alertTimer?.invalidate()
        alertTimer = nil
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - SwiftUI Lockdown Content

struct LockdownContentView: View {
    let reason: String
    @State private var pulseOpacity: Double = 0.6

    var body: some View {
        ZStack {
            // Dark red background
            Color.black.opacity(0.92)

            // Red vignette
            RadialGradient(
                colors: [Color.red.opacity(0.15), Color.clear],
                center: .center,
                startRadius: 100,
                endRadius: 600
            )

            VStack(spacing: 24) {
                Spacer()

                // Lock icon
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.red)
                    .opacity(pulseOpacity)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseOpacity)

                Text("SECURITY ALERT")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.red)

                Text("System integrity compromised")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))

                // Reason box
                VStack(spacing: 8) {
                    Text("Reason:")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(reason)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)

                Text("Executer has been locked for your safety.\nPlease reinstall from the official source.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)

                // Reinstall button
                Button {
                    if let url = URL(string: "https://github.com/allenwuzhouhan-web/executer/releases") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Reinstall Executer")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)

                // Quit button
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit Executer")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                Spacer()

                // Model + serial info
                VStack(spacing: 4) {
                    Text(AppModel.displayString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                    if DeviceSerial.hasSerial {
                        Text("Serial: \(DeviceSerial.serial)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            pulseOpacity = 1.0
        }
    }
}
