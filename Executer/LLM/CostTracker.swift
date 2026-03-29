import Foundation

/// Tracks API token usage and costs per provider.
/// Notifies user when over budget but NEVER blocks execution.
final class CostTracker {
    static let shared = CostTracker()

    // MARK: - Per-Provider Pricing (USD per 1M tokens)

    private let pricing: [String: (input: Double, output: Double)] = [
        "claude":   (input: 3.00,  output: 15.00),  // Claude Sonnet
        "deepseek": (input: 0.14,  output: 0.28),   // DeepSeek Chat
        "gemini":   (input: 0.075, output: 0.30),    // Gemini Flash
        "kimi":     (input: 0.70,  output: 0.70),    // Kimi
        "minimax":  (input: 0.15,  output: 0.15),    // MiniMax
    ]

    // MARK: - State

    private var dailyInputTokens: Int = 0
    private var dailyOutputTokens: Int = 0
    private var dailyCostUSD: Double = 0.0
    private var monthlyCostUSD: Double = 0.0
    private var lastResetDate: Date
    private var lastMonthlyResetDate: Date
    private var hasNotifiedToday = false

    private let lock = NSLock()
    private let defaults = UserDefaults.standard

    // MARK: - Budget Thresholds (user-configurable, notification only)

    var dailyBudgetUSD: Double {
        get { defaults.double(forKey: "cost_daily_budget") }
        set { defaults.set(newValue, forKey: "cost_daily_budget") }
    }

    var monthlyBudgetUSD: Double {
        get { defaults.double(forKey: "cost_monthly_budget") }
        set { defaults.set(newValue, forKey: "cost_monthly_budget") }
    }

    private init() {
        // Set default budgets if not configured
        if defaults.object(forKey: "cost_daily_budget") == nil {
            defaults.set(5.0, forKey: "cost_daily_budget")
        }
        if defaults.object(forKey: "cost_monthly_budget") == nil {
            defaults.set(50.0, forKey: "cost_monthly_budget")
        }

        // Load persisted counters
        dailyCostUSD = defaults.double(forKey: "cost_daily_total")
        monthlyCostUSD = defaults.double(forKey: "cost_monthly_total")
        dailyInputTokens = defaults.integer(forKey: "cost_daily_input_tokens")
        dailyOutputTokens = defaults.integer(forKey: "cost_daily_output_tokens")
        lastResetDate = defaults.object(forKey: "cost_last_reset") as? Date ?? Date()
        lastMonthlyResetDate = defaults.object(forKey: "cost_last_monthly_reset") as? Date ?? Date()

        checkAndResetIfNeeded()
    }

    // MARK: - Recording

    /// Record token usage from an API call. Call after each LLM response.
    func record(provider: String, inputTokens: Int, outputTokens: Int) {
        lock.lock()
        defer { lock.unlock() }

        checkAndResetIfNeeded()

        let providerKey = provider.lowercased()
        let rates = pricing[providerKey] ?? (input: 1.0, output: 1.0)

        let inputCost = Double(inputTokens) / 1_000_000 * rates.input
        let outputCost = Double(outputTokens) / 1_000_000 * rates.output
        let callCost = inputCost + outputCost

        dailyInputTokens += inputTokens
        dailyOutputTokens += outputTokens
        dailyCostUSD += callCost
        monthlyCostUSD += callCost

        // Persist
        defaults.set(dailyCostUSD, forKey: "cost_daily_total")
        defaults.set(monthlyCostUSD, forKey: "cost_monthly_total")
        defaults.set(dailyInputTokens, forKey: "cost_daily_input_tokens")
        defaults.set(dailyOutputTokens, forKey: "cost_daily_output_tokens")

        // Notify if over budget (but do NOT block)
        if !hasNotifiedToday && dailyCostUSD > dailyBudgetUSD {
            hasNotifiedToday = true
            let message = String(format: "Daily API spend: $%.2f (budget: $%.2f)", dailyCostUSD, dailyBudgetUSD)
            print("[CostTracker] \(message)")
            // Post notification for UI to pick up
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .costBudgetExceeded, object: nil, userInfo: ["message": message])
            }
        }
    }

    // MARK: - Queries

    /// Check if daily spending exceeds budget threshold.
    func isOverDailyBudget() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return dailyCostUSD > dailyBudgetUSD
    }

    /// Get a formatted daily cost report.
    func dailyReport() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(format: "Today: $%.2f / $%.2f budget | %d input + %d output tokens | Month: $%.2f / $%.2f",
                      dailyCostUSD, dailyBudgetUSD,
                      dailyInputTokens, dailyOutputTokens,
                      monthlyCostUSD, monthlyBudgetUSD)
    }

    // MARK: - Reset

    private func checkAndResetIfNeeded() {
        let calendar = Calendar.current
        let now = Date()

        // Daily reset
        if !calendar.isDate(lastResetDate, inSameDayAs: now) {
            dailyCostUSD = 0
            dailyInputTokens = 0
            dailyOutputTokens = 0
            hasNotifiedToday = false
            lastResetDate = now
            defaults.set(0.0, forKey: "cost_daily_total")
            defaults.set(0, forKey: "cost_daily_input_tokens")
            defaults.set(0, forKey: "cost_daily_output_tokens")
            defaults.set(now, forKey: "cost_last_reset")
        }

        // Monthly reset
        if calendar.component(.month, from: lastMonthlyResetDate) != calendar.component(.month, from: now) {
            monthlyCostUSD = 0
            lastMonthlyResetDate = now
            defaults.set(0.0, forKey: "cost_monthly_total")
            defaults.set(now, forKey: "cost_last_monthly_reset")
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let costBudgetExceeded = Notification.Name("com.executer.costBudgetExceeded")
}
