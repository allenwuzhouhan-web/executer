import SwiftUI

/// Settings tab for managing agent profiles.
struct AgentSettingsTab: View {
    @State private var profiles: [AgentProfile] = AgentRegistry.shared.allProfiles()
    @State private var selectedId: String? = nil
    @State private var showDeleteAlert = false
    @State private var deleteTarget: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Profiles")
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            Text("Agents scope which tools, memory, and system prompt the LLM uses per domain. Scoped agents send fewer tool schemas, reducing cost and improving accuracy.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)

            // Agent list
            List(selection: $selectedId) {
                ForEach(profiles, id: \.id) { profile in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: profile.color) ?? .gray)
                            .frame(width: 10, height: 10)

                        Image(systemName: profile.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.displayName)
                                .font(.system(size: 13, weight: .medium, design: .rounded))

                            HStack(spacing: 6) {
                                let toolCount = profile.allowedToolIDs?.count ?? 220
                                Text("\(toolCount) tools")
                                    .font(.system(size: 10, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary)

                                Text("ns: \(profile.memoryNamespace)")
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()

                        if profile.isBuiltIn {
                            Text("Built-in")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(profile.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 200)

            // Detail for selected
            if let id = selectedId, let profile = profiles.first(where: { $0.id == id }) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("ID", value: profile.id)
                        LabeledContent("Memory Namespace", value: profile.memoryNamespace)
                        LabeledContent("Model Override", value: profile.modelOverride ?? "Default")
                        LabeledContent("Keywords", value: "\(profile.keywords.count) keywords")

                        if let override = profile.systemPromptOverride {
                            Text("System Prompt Override:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(override)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .font(.system(size: 12, design: .rounded))
                }

                if !profile.isBuiltIn {
                    Button(role: .destructive) {
                        deleteTarget = profile.id
                        showDeleteAlert = true
                    } label: {
                        Label("Delete Agent", systemImage: "trash")
                    }
                }
            }
        }
        .padding()
        .alert("Delete Agent?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = deleteTarget {
                    try? AgentRegistry.shared.removeCustom(id)
                    profiles = AgentRegistry.shared.allProfiles()
                    selectedId = nil
                }
            }
        } message: {
            Text("This will permanently remove the agent profile.")
        }
        .onAppear {
            profiles = AgentRegistry.shared.allProfiles()
        }
    }
}
