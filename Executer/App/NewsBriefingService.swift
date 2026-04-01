import Foundation
import Cocoa

/// Daily auto-briefing service — fetches top headlines and shows a beautiful card on first use of the day.
class NewsBriefingService {
    static let shared = NewsBriefingService()
    private init() {}

    private let lastBriefingKey = "last_news_briefing_date"

    /// Called on app launch. If >20h since last briefing and a NewsAPI key exists, show a news card.
    func checkIfDue(appState: AppState) {
        guard NewsKeyStore.hasKey() else { return }

        let lastBriefing = UserDefaults.standard.object(forKey: lastBriefingKey) as? Date ?? .distantPast
        let hoursSince = Date().timeIntervalSince(lastBriefing) / 3600

        guard hoursSince >= 20 else {
            print("[NewsBriefing] Last briefing was \(String(format: "%.1f", hoursSince))h ago, skipping")
            return
        }

        // Wait 8 seconds for UI and health check to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            Task {
                await self.runBriefing(appState: appState)
            }
        }
    }

    private func runBriefing(appState: AppState) async {
        print("[NewsBriefing] Fetching daily headlines...")

        guard let apiKey = NewsKeyStore.getKey() else { return }

        do {
            let articles = try await fetchTopHeadlines(apiKey: apiKey, count: 6)
            guard !articles.isEmpty else {
                print("[NewsBriefing] No articles returned")
                return
            }

            // Save briefing date
            UserDefaults.standard.set(Date(), forKey: lastBriefingKey)

            await MainActor.run {
                appState.showInputBar()
                appState.inputBarState = .newsBriefing(articles: articles)
            }
        } catch {
            print("[NewsBriefing] Failed: \(error.localizedDescription)")
        }
    }

    private func fetchTopHeadlines(apiKey: String, count: Int) async throws -> [NewsBriefingArticle] {
        var components = URLComponents(string: "https://newsapi.org/v2/top-headlines")!
        components.queryItems = [
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "pageSize", value: String(count)),
            URLQueryItem(name: "apiKey", value: apiKey)
        ]

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, response) = try await PinnedURLSession.shared.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawArticles = json["articles"] as? [[String: Any]] else { return [] }

        return rawArticles.prefix(count).compactMap { raw in
            guard let title = raw["title"] as? String, !title.isEmpty,
                  title != "[Removed]" else { return nil }
            let source = (raw["source"] as? [String: Any])?["name"] as? String ?? "News"
            let desc = raw["description"] as? String
            let url = raw["url"] as? String ?? ""
            return NewsBriefingArticle(source: source, title: title, description: desc, url: url)
        }
    }
}

/// Lightweight model for the briefing card — separate from the executor's NewsArticle.
struct NewsBriefingArticle: Equatable {
    let source: String
    let title: String
    let description: String?
    let url: String
}
