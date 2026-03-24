import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var llmManager = LLMServiceManager.shared
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var keySaved = false
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        TabView {
            aiModelTab
                .tabItem { Label("AI Model", systemImage: "cpu") }
            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            voiceTab
                .tabItem { Label("Voice", systemImage: "mic.circle") }
            notchTab
                .tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            loadKeyForCurrentProvider()
        }
    }

    // MARK: - AI Model

    private var aiModelTab: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $llmManager.currentProvider) {
                    ForEach(LLMProvider.allCases, id: \.self) { provider in
                        Text(provider.config.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: llmManager.currentProvider) { _ in
                    llmManager.currentModel = llmManager.currentProvider.config.defaultModel
                    loadKeyForCurrentProvider()
                    testResult = nil
                    keySaved = APIKeyManager.shared.hasKey(for: llmManager.currentProvider)
                }
            }

            Section("Model") {
                Picker("Model", selection: $llmManager.currentModel) {
                    ForEach(llmManager.currentProvider.config.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }

            Section("\(llmManager.currentProvider.config.displayName) API Key") {
                HStack {
                    if showKey {
                        TextField(llmManager.currentProvider.config.keyPlaceholder, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(llmManager.currentProvider.config.keyPlaceholder, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(showKey ? "Hide" : "Show") {
                        showKey.toggle()
                    }
                    .frame(width: 50)
                }

                HStack {
                    Button("Save Key") {
                        APIKeyManager.shared.setKey(apiKey, for: llmManager.currentProvider)
                        keySaved = true
                    }
                    .disabled(apiKey.isEmpty)

                    if keySaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Key saved")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Get your API key at \(llmManager.currentProvider.config.signupURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Button(isTesting ? "Testing..." : "Test API Key") {
                        testAPIKey()
                    }
                    .disabled(apiKey.isEmpty || isTesting)

                    if let result = testResult {
                        if result.starts(with: "OK") {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(result)
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(result)
                                .foregroundStyle(.red)
                                .font(.caption)
                                .lineLimit(5)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section("Activation") {
                Text("Click the notch or press Cmd+Shift+Space to open the command bar")
                    .foregroundStyle(.secondary)
            }

            Section("Personality") {
                Toggle("Humor Mode", isOn: Binding(
                    get: { HumorMode.shared.isEnabled },
                    set: { HumorMode.shared.isEnabled = $0 }
                ))

                Text("Makes your Mac your unhinged best friend. Status messages become chaotic and fun.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                HStack {
                    Text("\(CommandHistory.shared.entries.count) commands in history")
                    Spacer()
                    Button("Clear History") {
                        CommandHistory.shared.clear()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        Form {
            Section("Required Permissions") {
                permissionRow(
                    name: "Accessibility",
                    description: "Required for system control and window management",
                    granted: permissions.accessibilityGranted,
                    action: { permissions.requestAccessibility() }
                )

                permissionRow(
                    name: "Input Monitoring",
                    description: "Required for notch click detection (CGEvent tap)",
                    granted: permissions.eventTapAvailable,
                    action: { permissions.requestEventTapAccess() }
                )

                permissionRow(
                    name: "Notifications",
                    description: "Timer alerts, status notifications",
                    granted: permissions.notificationsGranted,
                    action: { permissions.requestNotifications() }
                )

                permissionRow(
                    name: "Automation (Apple Events)",
                    description: "Required for controlling apps via AppleScript (Music, System Events, etc.)",
                    granted: permissions.appleEventsGranted,
                    action: { permissions.openAutomationSettings() }
                )
            }

            Section {
                Button("Refresh Permission Status") {
                    permissions.checkAll()
                }

                Text("After granting permissions in System Settings, click Refresh or restart the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Grant When Prompted") {
                Text("These are requested automatically when first needed:")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Label("Calendar & Reminders", systemImage: "calendar")
                Label("Screen Recording", systemImage: "rectangle.dashed.badge.record")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            permissions.checkAll()
        }
    }

    // MARK: - Notch Configuration

    @State private var zoneX: String = ""
    @State private var zoneY: String = ""
    @State private var zoneW: String = ""
    @State private var zoneH: String = ""
    @State private var zoneSaved = false

    private var notchTab: some View {
        Form {
            Section("Notch Click Zone") {
                Text("Define the screen area that triggers the command bar when clicked. Coordinates use the screenshot tool system (origin = top-left, use Cmd+Shift+4 to find coordinates).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    VStack(alignment: .leading) {
                        Text("X").font(.caption).foregroundStyle(.secondary)
                        TextField("X", text: $zoneX)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    VStack(alignment: .leading) {
                        Text("Y").font(.caption).foregroundStyle(.secondary)
                        TextField("Y", text: $zoneY)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    VStack(alignment: .leading) {
                        Text("Width").font(.caption).foregroundStyle(.secondary)
                        TextField("W", text: $zoneW)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    VStack(alignment: .leading) {
                        Text("Height").font(.caption).foregroundStyle(.secondary)
                        TextField("H", text: $zoneH)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                }

                HStack {
                    Button("Save Zone") {
                        let x = Double(zoneX) ?? 0
                        let y = Double(zoneY) ?? 0
                        let w = Double(zoneW) ?? 300
                        let h = Double(zoneH) ?? 38
                        let rect = CGRect(x: x, y: y, width: w, height: h)
                        print("[Settings] Saving zone: \(rect)")
                        appState.updateNotchZone(rect)
                        zoneSaved = true
                        print("[Settings] zoneSaved = \(zoneSaved)")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Reset to Auto") {
                        UserDefaults.standard.removeObject(forKey: "notch_click_zone")
                        let auto = NotchDetector.autoDetectZone()
                        appState.updateNotchZone(auto)
                        loadCurrentZone()
                        zoneSaved = true
                    }

                    if zoneSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Saved!")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                Text("Tip: Use Cmd+Shift+4 to find the coordinates of your notch area, then enter them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Shortcut") {
                Text("Cmd+Shift+Space also opens the command bar (works even without notch click).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            zoneSaved = false
            loadCurrentZone()
        }
    }

    private func loadCurrentZone() {
        let zone = NotchDetector.autoDetectZone()
        if let saved = UserDefaults.standard.string(forKey: "notch_click_zone") {
            let rect = NSRectFromString(saved)
            if rect.width > 0 {
                zoneX = String(Int(rect.origin.x))
                zoneY = String(Int(rect.origin.y))
                zoneW = String(Int(rect.size.width))
                zoneH = String(Int(rect.size.height))
                return
            }
        }
        zoneX = String(Int(zone.origin.x))
        zoneY = String(Int(zone.origin.y))
        zoneW = String(Int(zone.size.width))
        zoneH = String(Int(zone.size.height))
    }

    private func permissionRow(name: String, description: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name).font(.headline)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("Grant") { action() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
    }

    // MARK: - Voice

    @State private var assistantName: String = ""
    @State private var nameSaved = false
    @ObservedObject private var calibration = VoiceCalibration.shared

    private var voiceTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero header
                VStack(spacing: 6) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.linearGradient(
                            colors: [.purple, .blue, .cyan],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    Text("Voice Input")
                        .font(.title2.bold())
                    Text("Cmd+Shift+V")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .padding(.top, 8)

                // Enable toggle card
                voiceCardSection {
                    HStack {
                        Image(systemName: "power.circle.fill")
                            .font(.title3)
                            .foregroundStyle(VoiceService.shared.isEnabled ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice Input")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Speak commands hands-free")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { VoiceService.shared.isEnabled },
                            set: { VoiceService.shared.isEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }

                // Always listening toggle
                voiceCardSection {
                    HStack {
                        Image(systemName: "ear.fill")
                            .font(.title3)
                            .foregroundStyle(VoiceService.shared.alwaysListening ? .cyan : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Always Listening")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Say \"\(AssistantNameManager.shared.name)\" to activate")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { VoiceService.shared.alwaysListening },
                            set: { VoiceService.shared.alwaysListening = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
                .opacity(VoiceService.shared.isEnabled ? 1 : 0.4)
                .disabled(!VoiceService.shared.isEnabled)

                // Assistant name card
                voiceCardSection {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.purple)
                            Text("Assistant Name")
                                .font(.system(size: 13, weight: .semibold))
                        }

                        HStack(spacing: 8) {
                            TextField("Name your assistant", text: $assistantName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { saveAssistantName() }

                            Button(action: saveAssistantName) {
                                Text("Save")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(assistantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                      assistantName.trimmingCharacters(in: .whitespacesAndNewlines) == AssistantNameManager.shared.name)

                            if nameSaved {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }

                        // Phrase examples
                        let name = AssistantNameManager.shared.name
                        HStack(spacing: 6) {
                            ForEach(["\(name) ...", "hey \(name)", "help \(name)", "\(name) bro"], id: \.self) { phrase in
                                Text(phrase)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }

                // Calibration card
                voiceCardSection {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.badge.mic")
                                .font(.title3)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Voice Training")
                                    .font(.system(size: 13, weight: .semibold))
                                if calibration.isCalibrated {
                                    Text("\(AssistantNameManager.shared.learnedVariants.count) patterns learned")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer()
                            if calibration.isCalibrated {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                            }
                        }

                        calibrationContent
                    }
                }

                // Permissions card
                voiceCardSection {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            Text("Permissions")
                                .font(.system(size: 13, weight: .semibold))
                        }

                        compactPermissionRow(
                            icon: "mic.fill", name: "Microphone",
                            granted: permissions.microphoneGranted,
                            action: { permissions.requestMicrophone() }
                        )
                        compactPermissionRow(
                            icon: "brain.head.profile.fill", name: "Speech Recognition",
                            granted: permissions.speechRecognitionGranted,
                            action: { permissions.requestSpeechRecognition() }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onAppear {
            assistantName = AssistantNameManager.shared.name
            nameSaved = false
            permissions.refreshMicrophone()
            permissions.refreshSpeechRecognition()
        }
    }

    private func saveAssistantName() {
        let trimmed = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != AssistantNameManager.shared.name else { return }
        AssistantNameManager.shared.name = trimmed
        AssistantNameManager.shared.clearLearnedVariants()
        assistantName = trimmed
        withAnimation(.spring(response: 0.3)) { nameSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { nameSaved = false }
        }
    }

    @ViewBuilder
    private var calibrationContent: some View {
        switch calibration.calibrationState {
        case .idle, .done:
            Button {
                calibration.startCalibration()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: calibration.isCalibrated ? "arrow.triangle.2.circlepath" : "mic.badge.plus")
                        .font(.system(size: 11))
                    Text(calibration.isCalibrated ? "Re-train" : "Start Training")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Text("Record 3 short samples so the app learns how you say \"\(AssistantNameManager.shared.name)\".")
                .font(.caption2)
                .foregroundStyle(.tertiary)

        case .waitingToRecord(let sample), .recording(let sample):
            VStack(spacing: 8) {
                // Progress dots
                HStack(spacing: 12) {
                    ForEach(1...3, id: \.self) { i in
                        Circle()
                            .fill(i < sample ? Color.green : (i == sample ? Color.red : Color.gray.opacity(0.3)))
                            .frame(width: 10, height: 10)
                            .overlay {
                                if i == sample {
                                    Circle()
                                        .stroke(.red.opacity(0.5), lineWidth: 2)
                                        .frame(width: 18, height: 18)
                                }
                            }
                    }
                }

                Text(calibration.currentPrompt)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                if case .recording = calibration.calibrationState {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 10))
                        Text("Listening...")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                if !calibration.lastHeard.isEmpty {
                    Text("\"\(calibration.lastHeard)\"")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Button("Cancel") { calibration.cancelCalibration() }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Learning...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error(let msg):
            VStack(spacing: 6) {
                Label(msg, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") { calibration.startCalibration() }
                    .font(.caption)
            }
        }

        if !AssistantNameManager.shared.learnedVariants.isEmpty,
           calibration.calibrationState == .idle || calibration.calibrationState == .done {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(AssistantNameManager.shared.learnedVariants, id: \.self) { variant in
                        Text(variant)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text("Learned patterns")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func voiceCardSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
    }

    private func compactPermissionRow(icon: String, name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12))
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            } else {
                Button("Grant") { action() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Executer")
                .font(.title.bold())

            Text("Click the notch. Command your Mac.")
                .foregroundStyle(.secondary)

            Text("Powered by \(llmManager.currentProvider.config.displayName)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("\(ToolRegistry.shared.count) tools available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    private func loadKeyForCurrentProvider() {
        apiKey = APIKeyManager.shared.getKey(for: llmManager.currentProvider) ?? ""
        keySaved = APIKeyManager.shared.hasKey(for: llmManager.currentProvider)
        showKey = false
        testResult = nil
    }

    private func testAPIKey() {
        APIKeyManager.shared.setKey(apiKey, for: llmManager.currentProvider)
        keySaved = true
        isTesting = true
        testResult = nil

        Task.detached { [provider = llmManager.currentProvider, model = llmManager.currentModel] in
            do {
                let service: LLMServiceProtocol
                switch provider {
                case .claude:
                    service = AnthropicService(model: model)
                default:
                    service = OpenAICompatibleService(provider: provider, model: model)
                }

                let testMessages = [
                    ChatMessage(role: "user", content: "Say hi in 3 words.")
                ]
                let response = try await service.sendChatRequest(messages: testMessages, tools: nil, maxTokens: 20)

                await MainActor.run {
                    isTesting = false
                    if let text = response.text {
                        testResult = "OK: \"\(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))\""
                    } else {
                        testResult = "OK: Connected successfully"
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResult = "Error: \(error.localizedDescription.prefix(200))"
                }
            }
        }
    }
}
