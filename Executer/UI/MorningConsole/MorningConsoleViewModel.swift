import Foundation
import Combine

/// Protocol for any system that contributes items to the morning briefing.
protocol MorningConsoleContributor {
    func morningBriefingItems() async -> [BriefingItem]
}

/// A single item in the morning console.
struct BriefingItem: Identifiable {
    let id = UUID()
    let category: Category
    let title: String
    let detail: String
    let urgency: Double
    let actionCommand: String?    // Command to execute if user clicks action button
    let outputPath: String?       // File to preview if applicable

    enum Category: String {
        case completedWork = "Completed"
        case urgent = "Urgent"
        case calendar = "Calendar"
        case decision = "Decision"
        case fileSuggestion = "Files"
        case notification = "Notification"
        case trustUpdate = "Trust"
    }
}

/// Aggregates data from all pillars for the morning console.
@MainActor
class MorningConsoleViewModel: ObservableObject {
    @Published var items: [BriefingItem] = []
    @Published var isLoaded = false
    @Published var overnightReport: OvernightReport?

    func load() async {
        var allItems: [BriefingItem] = []

        // 1. Overnight completed tasks
        let completedTasks = OvernightTaskQueue.shared.completedTasks()
        for task in completedTasks.suffix(10) {
            allItems.append(BriefingItem(
                category: .completedWork,
                title: task.title,
                detail: task.result?.summary ?? task.description,
                urgency: 0.3,
                actionCommand: nil,
                outputPath: task.result?.outputPath
            ))
        }

        // 2. Tasks needing review
        let reviewTasks = OvernightTaskQueue.shared.needsReviewTasks()
        for task in reviewTasks {
            allItems.append(BriefingItem(
                category: .decision,
                title: "Review: \(task.title)",
                detail: task.result?.summary ?? task.description,
                urgency: 0.7,
                actionCommand: nil,
                outputPath: task.result?.outputPath
            ))
        }

        // 3. Urgent radar signals
        let urgentSignals = await InformationRadar.shared.urgentSignals(threshold: 0.6)
        for signal in urgentSignals.suffix(5) {
            allItems.append(BriefingItem(
                category: .urgent,
                title: signal.title,
                detail: signal.body,
                urgency: signal.urgency,
                actionCommand: nil,
                outputPath: nil
            ))
        }

        // 4. File organization suggestions
        let fileSuggestions = await SemanticFileOrganizer.shared.getSuggestions()
        for suggestion in fileSuggestions.prefix(5) {
            allItems.append(BriefingItem(
                category: .fileSuggestion,
                title: "Organize: \(suggestion.filename)",
                detail: "Move to \(suggestion.classification.projectName ?? "unknown") (\(Int(suggestion.classification.confidence * 100))% confident)",
                urgency: 0.3,
                actionCommand: "organize_file {\"file_path\": \"\(suggestion.filePath)\"}",
                outputPath: nil
            ))
        }

        // 5. Batched notifications from Adaptive Notifier
        let batched = await AdaptiveNotifier.shared.consumeBatchedMessages()
        for msg in batched {
            allItems.append(BriefingItem(
                category: .notification,
                title: msg.title,
                detail: msg.body,
                urgency: msg.urgency,
                actionCommand: nil,
                outputPath: nil
            ))
        }

        // 6. Trust updates
        let trustReport = TrustRatchet.trustReport()
        if !trustReport.contains("No trust history") {
            allItems.append(BriefingItem(
                category: .trustUpdate,
                title: "Trust Status",
                detail: trustReport,
                urgency: 0.1,
                actionCommand: nil,
                outputPath: nil
            ))
        }

        // Sort by urgency (most urgent first)
        allItems.sort { $0.urgency > $1.urgency }

        self.items = allItems
        self.isLoaded = true
    }

    var completedItems: [BriefingItem] { items.filter { $0.category == .completedWork } }
    var urgentItems: [BriefingItem] { items.filter { $0.category == .urgent } }
    var decisionItems: [BriefingItem] { items.filter { $0.category == .decision } }
    var calendarItems: [BriefingItem] { items.filter { $0.category == .calendar } }
    var fileItems: [BriefingItem] { items.filter { $0.category == .fileSuggestion } }
    var notificationItems: [BriefingItem] { items.filter { $0.category == .notification } }
}
