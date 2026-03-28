import SwiftUI

// MARK: - Main Welcome View

struct WelcomeView: View {
    @State private var currentPage = 0
    @State private var appeared = false
    let onComplete: () -> Void

    private let pageCount = 4

    var body: some View {
        ZStack {
            AnimatedGradientBackground()

            VStack(spacing: 0) {
                // Page content with slide transition
                ZStack {
                    if currentPage == 0 {
                        WelcomePage1(appeared: $appeared)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                    if currentPage == 1 {
                        WelcomePage2()
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                    if currentPage == 2 {
                        WelcomePage3()
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                    if currentPage == 3 {
                        WelcomePage4(onComplete: onComplete)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Page indicator dots + navigation
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
        .frame(width: 560, height: 480)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                appeared = true
            }
        }
    }
}

// MARK: - Animated Gradient Background

struct AnimatedGradientBackground: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        LinearGradient(
            colors: [
                .purple.opacity(0.15),
                .blue.opacity(0.1),
                .pink.opacity(0.15),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .hueRotation(.degrees(phase))
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: true)) {
                phase = 60
            }
        }
    }
}

// MARK: - Page 1: Welcome

struct WelcomePage1: View {
    @Binding var appeared: Bool
    @State private var iconScale: CGFloat = 0
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var shimmerPhase: CGFloat = -1.0
    @State private var buttonOpacity: Double = 0

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // App icon with scale-up spring
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .purple.opacity(0.3), radius: 20, y: 8)
                .scaleEffect(iconScale)

            // Title with shimmer
            ZStack {
                Text("Executer")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .opacity(titleOpacity)

                Text("Executer")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .opacity(titleOpacity)
                    .mask(
                        GeometryReader { geo in
                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white.opacity(0.6),
                                    .clear,
                                ],
                                startPoint: UnitPoint(x: shimmerPhase, y: 0.5),
                                endPoint: UnitPoint(x: shimmerPhase + 0.4, y: 0.5)
                            )
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                    )
                    .blendMode(.screen)
            }

            Text("Your AI-powered macOS assistant")
                .font(.title3)
                .foregroundStyle(.secondary)
                .opacity(subtitleOpacity)

            Spacer()

            Text("Swipe or scroll to continue")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(buttonOpacity)

            Spacer().frame(height: 40)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1)) {
                iconScale = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                titleOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.6)) {
                subtitleOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.9)) {
                buttonOpacity = 1.0
            }
            withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false).delay(0.5)) {
                shimmerPhase = 1.5
            }
        }
    }
}

// MARK: - Page 2: Features

struct WelcomePage2: View {
    @State private var visibleCards: Set<Int> = []

    private let features: [(icon: String, title: String, desc: String)] = [
        ("desktopcomputer", "Control Your Mac", "Launch apps, adjust volume, dark mode, screenshots"),
        ("function", "Instant Math", "Unit conversions, formulas, calculations — no API needed"),
        ("magnifyingglass", "Research & Knowledge", "Web search, papers, formula database"),
        ("bubble.left.and.bubble.right.fill", "Multi-Platform Messaging", "WeChat, iMessage, WhatsApp"),
        ("mic.fill", "Voice Commands", "\"Hey Pip\" hands-free control"),
        ("globe", "6 Languages", "EN, \u{4E2D}\u{6587}, RU, ES, FR, \u{65E5}\u{672C}\u{8A9E}"),
    ]

    let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 16)

            Text("What It Can Do")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    FeatureCard(
                        icon: feature.icon,
                        title: feature.title,
                        description: feature.desc
                    )
                    .opacity(visibleCards.contains(index) ? 1 : 0)
                    .offset(y: visibleCards.contains(index) ? 0 : 20)
                }
            }
            .padding(.horizontal, 28)

            Spacer()
        }
        .onAppear {
            for i in 0..<features.count {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.1)) {
                    visibleCards.insert(i)
                }
            }
        }
    }
}

struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        )
    }
}

// MARK: - Page 3: Quick Setup

struct WelcomePage3: View {
    @State private var selectedLanguage: AppLanguage = LanguageManager.shared.currentLanguage
    @State private var selectedPlatform: MessagingPlatform = MessagingManager.shared.preferredPlatform
    @State private var contentOpacity: Double = 0

    var body: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 16)

            Text("Quick Setup")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            // Language selection
            VStack(spacing: 10) {
                Text("Choose Your Language")
                    .font(.headline)

                HStack(spacing: 8) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                selectedLanguage = lang
                                LanguageManager.shared.currentLanguage = lang
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Text(lang.flag)
                                    .font(.system(size: 28))
                                Text(lang.nativeName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(selectedLanguage == lang ? .primary : .secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selectedLanguage == lang ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selectedLanguage == lang ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()
                .padding(.horizontal, 40)

            // Messaging selection
            VStack(spacing: 10) {
                Text("Default Messaging")
                    .font(.headline)

                HStack(spacing: 16) {
                    ForEach(MessagingPlatform.allCases, id: \.self) { platform in
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                selectedPlatform = platform
                                MessagingManager.shared.preferredPlatform = platform
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: platform.icon)
                                    .font(.system(size: 26))
                                    .foregroundStyle(platform.color)
                                Text(platform.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(selectedPlatform == platform ? .primary : .secondary)
                            }
                            .frame(width: 90, height: 70)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selectedPlatform == platform ? platform.color.opacity(0.1) : Color.gray.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(selectedPlatform == platform ? platform.color.opacity(0.5) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("You can always change these in Settings")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .opacity(contentOpacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                contentOpacity = 1.0
            }
        }
    }
}

// MARK: - Page 4: Ready

struct WelcomePage4: View {
    let onComplete: () -> Void

    @State private var keyVisible: [Bool] = [false, false, false]
    @State private var sparkleOpacity: Double = 0
    @State private var sparkleScale: CGFloat = 0.5
    @State private var buttonOpacity: Double = 0
    @State private var sparkleRotation: Double = 0

    private let keys = ["\u{2318}", "\u{21E7}", "Space"]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("You're Ready!")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            // Keyboard shortcut display with sparkles
            ZStack {
                // Sparkle ring
                ForEach(0..<8, id: \.self) { i in
                    Circle()
                        .fill(sparkleColor(for: i))
                        .frame(width: 6, height: 6)
                        .offset(x: 80 * cos(Double(i) * .pi / 4 + sparkleRotation),
                                y: 50 * sin(Double(i) * .pi / 4 + sparkleRotation))
                        .opacity(sparkleOpacity)
                        .scaleEffect(sparkleScale)
                }

                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { i in
                        KeyCap(label: keys[i])
                            .scaleEffect(keyVisible[i] ? 1.0 : 0.01)
                            .opacity(keyVisible[i] ? 1.0 : 0)
                    }
                }
            }
            .frame(height: 80)

            Text("Press this anytime to summon Executer")
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                onComplete()
            } label: {
                Text("Start Using Executer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.purple, .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .shadow(color: .purple.opacity(0.3), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .opacity(buttonOpacity)
            .scaleEffect(buttonOpacity)

            Spacer().frame(height: 50)
        }
        .onAppear {
            // Sequential key pop-in
            for i in 0..<3 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(Double(i) * 0.15 + 0.2)) {
                    keyVisible[i] = true
                }
            }
            // Sparkle animation
            withAnimation(.easeOut(duration: 0.6).delay(0.7)) {
                sparkleOpacity = 0.7
                sparkleScale = 1.0
            }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false).delay(0.7)) {
                sparkleRotation = .pi * 2
            }
            // Button fade-in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(1.0)) {
                buttonOpacity = 1.0
            }
        }
    }

    private func sparkleColor(for index: Int) -> Color {
        let hue = Double(index) / 8.0
        return Color(hue: hue, saturation: 0.6, brightness: 1.0)
    }
}

struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: label == "Space" ? 16 : 22, weight: .medium, design: .rounded))
            .frame(width: label == "Space" ? 80 : 50, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
    }
}

// MARK: - Offset helper for sparkle positioning

private func cos(_ angle: Double) -> CGFloat {
    CGFloat(Foundation.cos(angle))
}

private func sin(_ angle: Double) -> CGFloat {
    CGFloat(Foundation.sin(angle))
}
