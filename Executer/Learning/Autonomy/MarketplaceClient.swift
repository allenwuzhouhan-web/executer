import Foundation

/// Community workflow marketplace client.
///
/// Phase 18 of the Workflow Recorder ("The Agora").
/// Browse, search, download, upload, and rate community workflows.
/// Marketplace runs as a lightweight REST API; this client handles
/// all network interactions and local caching.
actor MarketplaceClient {
    static let shared = MarketplaceClient()

    // MARK: - Configuration

    /// Marketplace API base URL. Configurable for self-hosted instances.
    private var baseURL: URL = URL(string: "https://marketplace.executer.app/api/v1")!

    /// Local cache of browsed listings (to avoid redundant fetches).
    private var listingCache: [String: CachedListings] = [:]
    private let cacheTTL: TimeInterval = 300  // 5 minutes

    /// Installed marketplace workflows (tracked locally).
    private var installedWorkflows: Set<UUID> = []

    struct CachedListings {
        let listings: [MarketplaceListing]
        let fetchedAt: Date
    }

    // MARK: - Browse

    /// Browse featured workflows.
    func featured(limit: Int = 20) async -> [MarketplaceListing] {
        return await fetchListings(endpoint: "workflows/featured?limit=\(limit)")
    }

    /// Browse by category.
    func browseCategory(_ category: String, limit: Int = 20) async -> [MarketplaceListing] {
        let encoded = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
        return await fetchListings(endpoint: "workflows?category=\(encoded)&limit=\(limit)")
    }

    /// Search the marketplace.
    func search(query: String, limit: Int = 20) async -> [MarketplaceListing] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return await fetchListings(endpoint: "workflows/search?q=\(encoded)&limit=\(limit)")
    }

    // MARK: - Download

    /// Download a workflow from the marketplace.
    func download(listingId: UUID) async -> DownloadResult {
        let endpoint = "workflows/\(listingId.uuidString)/download"
        guard let url = URL(string: "\(baseURL)/\(endpoint)") else {
            return DownloadResult(status: .failed, workflow: nil, error: "Invalid URL")
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return DownloadResult(status: .failed, workflow: nil, error: "Server error")
            }

            // Import via WorkflowPackager
            let importResult = try WorkflowPackager.importFromData(data)
            if let workflow = importResult.workflow {
                // Save locally
                JournalStore.shared.insertGeneralizedWorkflow(workflow)
                installedWorkflows.insert(workflow.id)

                return DownloadResult(
                    status: importResult.status == .ready ? .success : .successWithWarnings,
                    workflow: workflow,
                    error: importResult.warnings.isEmpty ? nil : importResult.warnings.joined(separator: "; ")
                )
            }

            return DownloadResult(status: .failed, workflow: nil, error: importResult.warnings.joined(separator: "; "))
        } catch {
            return DownloadResult(status: .failed, workflow: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Upload

    /// Publish a workflow to the marketplace.
    func publish(workflow: GeneralizedWorkflow, description: String, tags: [String]) async -> PublishResult {
        do {
            let package = try WorkflowPackager.export(workflow)

            let payload = PublishPayload(
                name: workflow.name,
                description: description,
                category: workflow.category,
                tags: tags,
                stepCount: workflow.steps.count,
                parameterCount: workflow.parameters.count,
                requiredApps: workflow.applicability.requiredApps,
                packageData: package.workflowJSON,
                signature: package.signature
            )

            guard let url = URL(string: "\(baseURL)/workflows") else {
                return PublishResult(status: .failed, listingId: nil, error: "Invalid URL")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 201 else {
                return PublishResult(status: .failed, listingId: nil, error: "Upload failed")
            }

            if let result = try? JSONDecoder().decode(PublishResponse.self, from: data) {
                return PublishResult(status: .success, listingId: result.listingId, error: nil)
            }

            return PublishResult(status: .success, listingId: nil, error: nil)
        } catch {
            return PublishResult(status: .failed, listingId: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Rating

    /// Rate a marketplace workflow.
    func rate(listingId: UUID, stars: Int, review: String? = nil) async -> Bool {
        guard let url = URL(string: "\(baseURL)/workflows/\(listingId.uuidString)/rate") else { return false }

        let payload: [String: Any] = ["stars": stars, "review": review ?? ""]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return false }

        return true
    }

    // MARK: - Status

    func isInstalled(_ workflowId: UUID) -> Bool {
        installedWorkflows.contains(workflowId)
    }

    // MARK: - Networking

    private func fetchListings(endpoint: String) async -> [MarketplaceListing] {
        // Check cache
        if let cached = listingCache[endpoint],
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.listings
        }

        guard let url = URL(string: "\(baseURL)/\(endpoint)") else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            let listings = try JSONDecoder().decode([MarketplaceListing].self, from: data)
            listingCache[endpoint] = CachedListings(listings: listings, fetchedAt: Date())
            return listings
        } catch {
            print("[Marketplace] Fetch failed: \(error)")
            return []
        }
    }
}

// MARK: - Models

struct MarketplaceListing: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let category: String
    let tags: [String]
    let publisherName: String
    let publisherVerified: Bool
    let stepCount: Int
    let parameterCount: Int
    let requiredApps: [String]
    let downloadCount: Int
    let averageRating: Double
    let ratingCount: Int
    let version: Int
    let createdAt: Date
    let updatedAt: Date
}

struct DownloadResult: Sendable {
    let status: DownloadStatus
    let workflow: GeneralizedWorkflow?
    let error: String?

    enum DownloadStatus: String, Sendable {
        case success, successWithWarnings, failed
    }
}

struct PublishPayload: Codable {
    let name: String
    let description: String
    let category: String
    let tags: [String]
    let stepCount: Int
    let parameterCount: Int
    let requiredApps: [String]
    let packageData: String
    let signature: String
}

struct PublishResponse: Codable {
    let listingId: UUID
}

struct PublishResult: Sendable {
    let status: PublishStatus
    let listingId: UUID?
    let error: String?

    enum PublishStatus: String, Sendable { case success, failed }
}
