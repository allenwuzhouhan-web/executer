import SwiftUI

struct VoiceSettingsTab: View {
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var calibration = VoiceCalibration.shared
    @State private var assistantName: String = ""
    @State private var nameSaved = false

    var body: some View {
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

    // MARK: - Helpers

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
}
