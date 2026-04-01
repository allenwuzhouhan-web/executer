import SwiftUI

/// Unified onboarding flow — merges welcome carousel + permission setup into a single window.
/// Pages adapt: pre-release warning only shows for prerelease builds, permissions page auto-advances if already granted.
struct OnboardingView: View {
    @State private var currentPage = 0
    @State private var appeared = false
    let onComplete: () -> Void

    /// Whether to show the pre-release warning page (page 0).
    private var showPreRelease: Bool { AppModel.isPrerelease }

    /// Total page count adapts to build type.
    private var pageCount: Int { showPreRelease ? 6 : 5 }

    /// Map logical page index to actual page content.
    private func pageID(for index: Int) -> PageType {
        if showPreRelease {
            switch index {
            case 0: return .preRelease
            case 1: return .welcome
            case 2: return .features
            case 3: return .permissions
            case 4: return .quickSetup
            case 5: return .ready
            default: return .ready
            }
        } else {
            switch index {
            case 0: return .welcome
            case 1: return .features
            case 2: return .permissions
            case 3: return .quickSetup
            case 4: return .ready
            default: return .ready
            }
        }
    }

    private enum PageType {
        case preRelease, welcome, features, permissions, quickSetup, ready
    }

    var body: some View {
        ZStack {
            AnimatedGradientBackground()

            VStack(spacing: 0) {
                ZStack {
                    ForEach(0..<pageCount, id: \.self) { index in
                        if currentPage == index {
                            pageContent(for: pageID(for: index))
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Navigation dots + arrows
                HStack(spacing: 16) {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            currentPage = max(0, currentPage - 1)
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(currentPage > 0 ? 1 : 0)

                    HStack(spacing: 8) {
                        ForEach(0..<pageCount, id: \.self) { i in
                            Circle()
                                .fill(i == currentPage ? Color.accentColor : Color.gray.opacity(0.3))
                                .frame(width: 8, height: 8)
                                .scaleEffect(i == currentPage ? 1.2 : 1.0)
                                .animation(.spring(response: 0.3), value: currentPage)
                        }
                    }

                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            currentPage = min(pageCount - 1, currentPage + 1)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(currentPage < pageCount - 1 ? 1 : 0)
                }
                .padding(.bottom, 16)
            }
        }
        .frame(width: 580, height: 520)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private func pageContent(for page: PageType) -> some View {
        switch page {
        case .preRelease:
            PreReleaseWarningPage()
        case .welcome:
            WelcomePage1(appeared: $appeared)
        case .features:
            WelcomePage2()
        case .permissions:
            OnboardingPermissionsPage(onAutoAdvance: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    currentPage = min(pageCount - 1, currentPage + 1)
                }
            })
        case .quickSetup:
            WelcomePage3()
        case .ready:
            WelcomePage4(onComplete: onComplete)
        }
    }
}

// MARK: - Permissions Page (integrated into onboarding)

struct OnboardingPermissionsPage: View {
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var pollTimer: Timer?
    @State private var contentOpacity: Double = 0
    @State private var autoAdvanced = false
    @State private var skippedMessage = false

    var onAutoAdvance: () -> Void

    private var allGranted: Bool {
        permissions.accessibilityGranted && permissions.eventTapAvailable
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 16)

            // Header
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("Permissions")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Grant these two permissions once — you'll never be asked again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Permission rows
            VStack(spacing: 14) {
                permissionRow(
                    icon: "hand.raised.fill",
                    name: "Accessibility",
                    why: "Window control, app automation, keyboard shortcuts",
                    granted: permissions.accessibilityGranted,
                    action: { permissions.requestAccessibility() }
                )

                permissionRow(
                    icon: "keyboard",
                    name: "Input Monitoring",
                    why: "Notch clicks, global hotkeys, event capture",
                    granted: permissions.eventTapAvailable,
                    action: { permissions.requestEventTapAccess() }
                )
            }
            .padding(.horizontal, 36)

            // Status message
            if allGranted {
                Label("All set!", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else if skippedMessage {
                Text("These permissions help Executer work best.\nYou can grant them later in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            Spacer()
        }
        .opacity(contentOpacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                contentOpacity = 1.0
            }
            startPolling()

            // If permissions are already granted, auto-advance after a brief green checkmark flash
            if allGranted && !autoAdvanced {
                autoAdvanced = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    onAutoAdvance()
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
        .onChange(of: allGranted) { _, granted in
            if granted && !autoAdvanced {
                autoAdvanced = true
                pollTimer?.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    onAutoAdvance()
                }
            }
        }
    }

    private func permissionRow(icon: String, name: String, why: String,
                               granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 28)
                .animation(.spring(response: 0.3), value: granted)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Open Settings") { action() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(granted ? Color.green.opacity(0.06) : Color.orange.opacity(0.06))
        )
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            PermissionManager.shared.refreshAccessibility()
            PermissionManager.shared.refreshEventTap()
        }
    }
}
