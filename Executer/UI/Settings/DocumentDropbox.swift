import SwiftUI
import UniformTypeIdentifiers

/// Drag-and-drop zone for training the agent on reference documents.
/// Supports PPTX, DOCX, KEY, PDF, Pages, XLSX, Numbers.
struct DocumentDropbox: View {
    @State private var isDragHovering = false
    @State private var isTraining = false
    @State private var trainingProgress = ""
    @State private var trainedProfiles: [DocumentStudyProfile] = DocumentStudyStore.shared.profiles
    @State private var lastResult: DocumentStudyProfile?
    @State private var errorMessage: String?

    private let supportedExtensions: Set<String> = [
        "pptx", "docx", "doc", "key", "pages", "pdf", "xlsx", "xls", "numbers", "txt", "md", "rtf"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Label("Document Trainer", systemImage: "brain.head.profile")
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            Text("Drop reference documents here to train the agent. It will rigorously study the structure, style, content, and design patterns using a 3-agent pipeline (Planner \u{2192} Critic \u{2192} Writer).")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)

            // Drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isDragHovering ? Color.purple : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2, dash: isDragHovering ? [] : [8, 4])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isDragHovering ? Color.purple.opacity(0.08) : Color.clear)
                    )

                if isTraining {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(trainingProgress)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(isDragHovering ? .purple : .secondary)

                        Text("Drop PPTX, DOCX, KEY, PDF here")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(isDragHovering ? .purple : .secondary)

                        Text("Train on GOOD sources only")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(height: 100)
            .onDrop(of: [.fileURL], isTargeted: $isDragHovering) { providers in
                handleDrop(providers)
            }

            // Error message
            if let error = errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.red)
                }
            }

            // Last training result
            if let result = lastResult {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.sourceFile)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Spacer()
                            Text("\(String(format: "%.0f", result.qualityScore * 100))% quality")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(result.qualityScore >= 0.7 ? .green : .orange)
                        }
                        Text(result.summary.oneLiner)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            // Trained documents list
            if !trainedProfiles.isEmpty {
                Divider()

                HStack {
                    Text("Trained Documents (\(trainedProfiles.count))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(trainedProfiles, id: \.id) { profile in
                            HStack(spacing: 8) {
                                formatIcon(profile.sourceFormat)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.sourceFile)
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .lineLimit(1)
                                    Text(profile.content.domain)
                                        .font(.system(size: 9, weight: .regular, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                Text("\(profile.content.keyTerms.count) terms")
                                    .font(.system(size: 9, weight: .regular, design: .rounded))
                                    .foregroundStyle(.tertiary)

                                Circle()
                                    .fill(profile.qualityScore >= 0.7 ? .green : .orange)
                                    .frame(width: 6, height: 6)

                                Button {
                                    DocumentStudyStore.shared.delete(profile.id)
                                    trainedProfiles = DocumentStudyStore.shared.profiles
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isTraining else { return false }
        errorMessage = nil

        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let ext = url.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else {
                    DispatchQueue.main.async {
                        errorMessage = "Unsupported format: .\(ext)"
                    }
                    return
                }

                DispatchQueue.main.async { isTraining = true }

                Task {
                    do {
                        let profile = try await DocumentTrainer.shared.train(fileURL: url) { progress in
                            trainingProgress = progress
                        }
                        await MainActor.run {
                            lastResult = profile
                            trainedProfiles = DocumentStudyStore.shared.profiles
                            isTraining = false
                            trainingProgress = ""
                        }
                    } catch {
                        await MainActor.run {
                            errorMessage = error.localizedDescription
                            isTraining = false
                            trainingProgress = ""
                        }
                    }
                }
            }
        }
        return true
    }

    @ViewBuilder
    private func formatIcon(_ format: String) -> some View {
        switch format {
        case "pptx", "ppt", "key":
            Image(systemName: "rectangle.on.rectangle.angled")
        case "docx", "doc", "pages", "rtf":
            Image(systemName: "doc.text")
        case "xlsx", "xls", "numbers":
            Image(systemName: "tablecells")
        case "pdf":
            Image(systemName: "doc.richtext")
        default:
            Image(systemName: "doc")
        }
    }
}
