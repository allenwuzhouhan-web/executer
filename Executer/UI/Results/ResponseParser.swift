import Foundation

/// Parses LLM text output into structured RichResult types.
/// Uses NSDataDetector for dates, regex for markers, and heuristics for lists/news.
enum ResponseParser {

    /// Parse a raw LLM response into a RichResult.
    static func parse(_ message: String) -> RichResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try each parser in priority order
        if let event = parseEventMarker(trimmed) { return .event(event) }
        if let headlines = parseNewsHeadlines(trimmed), headlines.count >= 2 { return .news(headlines) }
        if let dateResult = parseDateResponse(trimmed) { return .date(dateResult) }
        if let listResult = parseList(trimmed) { return listResult }

        return .text(trimmed)
    }

    // MARK: - Event Marker: [EVENT: title | ISO-date | location]

    private static let eventPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\[EVENT:\s*(.+?)\s*\|\s*(.+?)\s*(?:\|\s*(.+?))?\s*\]"#,
            options: [.caseInsensitive]
        )
    }()

    private static func parseEventMarker(_ text: String) -> EventResult? {
        guard let regex = eventPattern else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        guard let match = regex.firstMatch(in: text, range: range) else { return nil }

        let title = nsText.substring(with: match.range(at: 1))
        let dateStr = nsText.substring(with: match.range(at: 2))
        let location: String? = match.range(at: 3).location != NSNotFound
            ? nsText.substring(with: match.range(at: 3))
            : nil

        // Parse date — try ISO 8601 first, then natural language
        guard let date = parseDate(dateStr) else { return nil }

        // Extract any surrounding text as notes
        let markerRange = match.range
        var notes = nsText.replacingCharacters(in: markerRange, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty { notes = nil as String? ?? "" }

        return EventResult(
            title: title,
            date: date,
            endDate: nil,
            location: location,
            notes: notes.isEmpty ? nil : notes
        )
    }

    // MARK: - News Headlines: [HEADLINE: title | source | summary | url]

    private static let headlinePattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\[HEADLINE:\s*(.+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*(?:\|\s*(.+?))?\s*\]"#,
            options: [.caseInsensitive]
        )
    }()

    private static func parseNewsHeadlines(_ text: String) -> [NewsHeadline]? {
        guard let regex = headlinePattern else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return nil }

        return matches.map { match in
            let title = nsText.substring(with: match.range(at: 1))
            let source = nsText.substring(with: match.range(at: 2))
            let summary = nsText.substring(with: match.range(at: 3))
            let url: String? = match.range(at: 4).location != NSNotFound
                ? nsText.substring(with: match.range(at: 4))
                : nil

            return NewsHeadline(title: title, source: source, summary: summary, url: url, timeAgo: nil)
        }
    }

    // MARK: - Date Detection via NSDataDetector

    private static func parseDateResponse(_ text: String) -> DateResult? {
        // Only consider short responses as date-centric (<300 chars)
        guard text.count < 300 else { return nil }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        guard let matches = detector?.matches(in: text, range: range),
              let firstMatch = matches.first,
              let date = firstMatch.date else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = firstMatch.duration > 0 ? .short : .none

        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full

        // Remaining text (without the date portion) is context
        let dateRange = firstMatch.range
        let context = nsText.replacingCharacters(in: dateRange, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:- "))

        return DateResult(
            date: date,
            formattedDate: formatter.string(from: date),
            context: context.isEmpty ? nil : context,
            relativeDescription: relative.localizedString(for: date, relativeTo: Date())
        )
    }

    // MARK: - List Detection (markdown numbered/bulleted lists)

    private static func parseList(_ text: String) -> RichResult? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count >= 3 else { return nil }

        // Check if most lines start with list markers
        let listPattern = #"^(?:\d+[\.\)]\s*|-\s*|\*\s*|•\s*)"#
        let regex = try? NSRegularExpression(pattern: listPattern)

        var listItems: [ListItem] = []
        var title: String?
        var listLineCount = 0

        for (i, line) in lines.enumerated() {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            if let match = regex?.firstMatch(in: line, range: range) {
                let content = nsLine.substring(from: match.range.upperBound)
                    .trimmingCharacters(in: .whitespaces)

                // Check for bold/emphasis prefix as detail separator
                let parts = content.components(separatedBy: " - ")
                if parts.count >= 2 {
                    listItems.append(ListItem(text: parts[0], detail: parts.dropFirst().joined(separator: " - ")))
                } else {
                    listItems.append(ListItem(text: content, detail: nil))
                }
                listLineCount += 1
            } else if i == 0 && listItems.isEmpty {
                // First non-list line could be a title/header
                title = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*: "))
            }
        }

        // Need at least 60% of lines to be list items
        let ratio = Double(listLineCount) / Double(lines.count)
        guard listItems.count >= 3 && ratio >= 0.5 else { return nil }

        return .list(title: title, items: listItems)
    }

    // MARK: - Date Parsing Helpers

    private static func parseDate(_ string: String) -> Date? {
        // Try ISO 8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }

        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }

        // Try common date formats
        let formats = ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "MMM d, yyyy", "MMMM d, yyyy", "MM/dd/yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: string) { return d }
        }

        // Try NSDataDetector as last resort
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(location: 0, length: (string as NSString).length)
        return detector?.firstMatch(in: string, range: range)?.date
    }
}
