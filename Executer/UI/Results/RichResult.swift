import Foundation

/// Typed result variants for structured UI rendering.
enum RichResult {
    case text(String)
    case date(DateResult)
    case event(EventResult)
    case news([NewsHeadline])
    case list(title: String?, items: [ListItem])
}

struct DateResult {
    let date: Date
    let formattedDate: String       // "Sunday, March 15, 2026"
    let context: String?            // additional context text from the response
    let relativeDescription: String // "in 2 weeks"
}

struct EventResult {
    let title: String
    let date: Date
    let endDate: Date?
    let location: String?
    let notes: String?
}

struct NewsHeadline: Identifiable {
    let id = UUID()
    let title: String
    let source: String
    let summary: String
    let url: String?
    let timeAgo: String?
}

struct ListItem: Identifiable {
    let id = UUID()
    let text: String
    let detail: String?
}
