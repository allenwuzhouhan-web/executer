import SwiftUI

/// Rich interactive morning briefing dashboard. Shows completed work, urgent items, calendar, decision queue.
struct MorningConsoleView: View {
    @StateObject private var viewModel = MorningConsoleViewModel()
    var onDismiss: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("Good Morning")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text(dateString())
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Dismiss") { onDismiss?() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 8)

                if !viewModel.isLoaded {
                    ProgressView("Loading briefing...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else if viewModel.items.isEmpty {
                    Text("Nothing to report — all quiet overnight.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    // Urgent items
                    if !viewModel.urgentItems.isEmpty {
                        sectionView(title: "Urgent", items: viewModel.urgentItems, color: .red)
                    }

                    // Decision items
                    if !viewModel.decisionItems.isEmpty {
                        sectionView(title: "Needs Your Decision", items: viewModel.decisionItems, color: .orange)
                    }

                    // Completed work
                    if !viewModel.completedItems.isEmpty {
                        sectionView(title: "Completed Overnight", items: viewModel.completedItems, color: .green)
                    }

                    // File suggestions
                    if !viewModel.fileItems.isEmpty {
                        sectionView(title: "File Organization", items: viewModel.fileItems, color: .blue)
                    }

                    // Notifications
                    if !viewModel.notificationItems.isEmpty {
                        sectionView(title: "Notifications", items: viewModel.notificationItems, color: .purple)
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private func sectionView(title: String, items: [BriefingItem], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.headline)
                Text("(\(items.count))")
                    .foregroundColor(.secondary)
            }

            ForEach(items) { item in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.body)
                            .fontWeight(.medium)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if item.actionCommand != nil {
                        Button("Act") {
                            // Execute the action command
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if item.outputPath != nil {
                        Button("Open") {
                            if let path = item.outputPath {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }
}
