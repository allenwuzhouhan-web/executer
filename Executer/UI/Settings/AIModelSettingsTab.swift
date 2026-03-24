import SwiftUI

struct AIModelSettingsTab: View {
    @ObservedObject private var llmManager = LLMServiceManager.shared
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var keySaved = false
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
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
        .onAppear {
            loadKeyForCurrentProvider()
        }
    }

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
