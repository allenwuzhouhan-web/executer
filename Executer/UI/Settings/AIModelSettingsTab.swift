import SwiftUI

struct AIModelSettingsTab: View {
    @ObservedObject private var llmManager = LLMServiceManager.shared
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var keySaved = false
    @State private var testResult: String?
    @State private var isTesting = false

    // Service API keys
    @State private var weatherKey: String = ""
    @State private var weatherKeySaved = false
    @State private var showWeatherKey = false

    @State private var newsKey: String = ""
    @State private var newsKeySaved = false
    @State private var showNewsKey = false

    @State private var scholarKey: String = ""
    @State private var scholarKeySaved = false
    @State private var showScholarKey = false

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

            Section {
                serviceKeyRow(
                    icon: "cloud.sun.fill",
                    iconColor: .orange,
                    name: "Weather",
                    placeholder: "WeatherAPI key",
                    signupHint: "weatherapi.com",
                    key: $weatherKey,
                    showKey: $showWeatherKey,
                    saved: $weatherKeySaved,
                    onSave: { WeatherKeyStore.setKey(weatherKey); weatherKeySaved = true },
                    onDelete: { WeatherKeyStore.delete(); weatherKey = ""; weatherKeySaved = false }
                )

                Divider()

                serviceKeyRow(
                    icon: "newspaper.fill",
                    iconColor: .blue,
                    name: "NewsAPI",
                    placeholder: "NewsAPI key",
                    signupHint: "newsapi.org",
                    key: $newsKey,
                    showKey: $showNewsKey,
                    saved: $newsKeySaved,
                    onSave: { NewsKeyStore.setKey(newsKey); newsKeySaved = true },
                    onDelete: { NewsKeyStore.delete(); newsKey = ""; newsKeySaved = false }
                )

                Divider()

                serviceKeyRow(
                    icon: "book.fill",
                    iconColor: .purple,
                    name: "Semantic Scholar",
                    placeholder: "Semantic Scholar API key",
                    signupHint: "semanticscholar.org/product/api",
                    key: $scholarKey,
                    showKey: $showScholarKey,
                    saved: $scholarKeySaved,
                    onSave: { SemanticScholarKeyStore.setKey(scholarKey); scholarKeySaved = true },
                    onDelete: { SemanticScholarKeyStore.delete(); scholarKey = ""; scholarKeySaved = false }
                )
            } header: {
                Label("Service API Keys", systemImage: "key.fill")
            } footer: {
                Text("These keys enable weather, news, and academic paper features. Each is optional — features gracefully degrade without them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Activation") {
                Text("Click the notch or press Cmd+Shift+Space to open the command bar")
                    .foregroundStyle(.secondary)
            }

            Section("Messaging") {
                Picker("Default Platform", selection: Binding(
                    get: { MessagingManager.shared.preferredPlatform },
                    set: { MessagingManager.shared.preferredPlatform = $0 }
                )) {
                    ForEach(MessagingPlatform.allCases, id: \.self) { p in
                        Label(p.displayName, systemImage: p.icon).tag(p)
                    }
                }

                Text("Used when you say \"tell mom hi\" without specifying a platform.")
                    .font(.caption)
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
            loadServiceKeys()
        }
    }

    // MARK: - Service Key Row

    private func serviceKeyRow(
        icon: String, iconColor: Color, name: String, placeholder: String,
        signupHint: String, key: Binding<String>, showKey: Binding<Bool>,
        saved: Binding<Bool>, onSave: @escaping () -> Void, onDelete: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                Text(name)
                    .font(.headline)

                Spacer()

                if saved.wrappedValue {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            HStack {
                if showKey.wrappedValue {
                    TextField(placeholder, text: key)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(placeholder, text: key)
                        .textFieldStyle(.roundedBorder)
                }

                Button(showKey.wrappedValue ? "Hide" : "Show") {
                    showKey.wrappedValue.toggle()
                }
                .frame(width: 50)
            }

            HStack(spacing: 12) {
                Button("Save") { onSave() }
                    .disabled(key.wrappedValue.isEmpty)

                if saved.wrappedValue {
                    Button("Remove", role: .destructive) { onDelete() }
                }

                Spacer()

                Text(signupHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Loading

    private func loadKeyForCurrentProvider() {
        apiKey = APIKeyManager.shared.getKey(for: llmManager.currentProvider) ?? ""
        keySaved = APIKeyManager.shared.hasKey(for: llmManager.currentProvider)
        showKey = false
        testResult = nil
    }

    private func loadServiceKeys() {
        weatherKey = WeatherKeyStore.getKey() ?? ""
        weatherKeySaved = WeatherKeyStore.hasKey()
        newsKey = NewsKeyStore.getKey() ?? ""
        newsKeySaved = NewsKeyStore.hasKey()
        scholarKey = SemanticScholarKeyStore.getKey() ?? ""
        scholarKeySaved = SemanticScholarKeyStore.hasKey()
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
