import Foundation

/// Filters ALL observation events before storage. Privacy-first, hard-coded rules.
/// ALL data stays local. Nothing leaves the machine. Ever.
final class PrivacyGuard: Sendable {
    static let shared = PrivacyGuard()

    // MARK: - Blacklists (hard-coded, not configurable by LLM)

    /// Apps that are NEVER observed — even app name is not logged.
    private let blacklistedBundleIds: Set<String> = [
        // Password managers
        "com.apple.keychainaccess",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.1password.1password",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.enpass.Enpass",
        // Sensitive system apps
        "com.apple.systempreferences",   // System Settings (may show password panels)
    ]

    /// URL domains that are NEVER logged.
    private let blacklistedDomains: Set<String> = [
        // Banking — major US
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com",
        "capitalone.com", "usbank.com", "pnc.com", "tdbank.com",
        // Banking — China
        "icbc.com.cn", "boc.cn", "ccb.com", "abchina.com",
        "cmbchina.com", "psbc.com", "bankcomm.com",
        // Banking — generic
        "online.citibank.com", "secure.bankofamerica.com",
        // Health portals
        "mychart.com", "patient.info", "myhealth.stanford.edu",
        "portal.myquest.com", "member.aetna.com",
        // Tax
        "turbotax.intuit.com", "irs.gov",
        // Password manager web
        "my.1password.com", "vault.bitwarden.com", "lastpass.com",
    ]

    /// Window titles containing these strings → skip the event entirely.
    /// Case-insensitive matching.
    private let blacklistedTitleKeywords: [String] = [
        "password", "密码", "passcode", "credential",
        "login", "登录", "sign in", "signin",
        "private browsing", "incognito", "隐私浏览",
        "keychain", "钥匙串",
        "credit card", "信用卡", "cvv",
        "social security", "ssn",
    ]

    // Pre-compiled regexes for sensitive data scrubbing
    private let emailPattern: NSRegularExpression
    private let phonePattern: NSRegularExpression
    private let creditCardPattern: NSRegularExpression
    private let ssnPattern: NSRegularExpression
    private let apiKeyPattern: NSRegularExpression
    private let tokenPattern: NSRegularExpression

    /// Runtime user-added blacklist (persists via UserDefaults).
    private let userBlacklistKey = "oe_user_blacklisted_apps"

    private init() {
        // Pre-compile all regexes at init — never recompile on hot path
        emailPattern = try! NSRegularExpression(pattern: #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#)
        phonePattern = try! NSRegularExpression(pattern: #"(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#)
        creditCardPattern = try! NSRegularExpression(pattern: #"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b"#)
        ssnPattern = try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)
        apiKeyPattern = try! NSRegularExpression(pattern: #"\b(?:sk-|AIza|eyJ|ghp_|gho_|Bearer\s+)[A-Za-z0-9_\-]{20,}\b"#)
        tokenPattern = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9_\-]{40,}\b"#)
    }

    // MARK: - App Filtering

    func shouldObserveApp(bundleId: String) -> Bool {
        if blacklistedBundleIds.contains(bundleId) { return false }
        if userBlacklistedApps.contains(bundleId) { return false }
        return true
    }

    // MARK: - Domain Filtering

    func shouldObserveDomain(_ domain: String) -> Bool {
        let lowered = domain.lowercased()
        // Exact match
        if blacklistedDomains.contains(lowered) { return false }
        // Subdomain match: "secure.chase.com" → blocked because "chase.com" is blacklisted
        for blocked in blacklistedDomains {
            if lowered.hasSuffix(".\(blocked)") { return false }
        }
        return true
    }

    // MARK: - Window Title Filtering

    func shouldObserveWindowTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        for keyword in blacklistedTitleKeywords {
            if lowered.contains(keyword) { return false }
        }
        return true
    }

    // MARK: - URL Sanitization

    /// Strip query parameters from URLs — they often contain tokens, personal data.
    /// Returns (domain, path) or nil if the URL is blacklisted.
    func sanitizeURL(_ urlString: String) -> (domain: String, path: String)? {
        guard let components = URLComponents(string: urlString) else {
            // Fallback: try to extract domain from string
            return extractDomainFromString(urlString)
        }
        let domain = (components.host ?? "").lowercased()
            .replacingOccurrences(of: "www.", with: "")
        guard shouldObserveDomain(domain) else { return nil }
        let path = components.path
        return (domain, path)
    }

    private func extractDomainFromString(_ str: String) -> (domain: String, path: String)? {
        // Handle cases like "google.com/search" without scheme
        let cleaned = str.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let parts = cleaned.split(separator: "/", maxSplits: 1)
        let domain = String(parts.first ?? "").lowercased()
            .replacingOccurrences(of: "www.", with: "")
        guard !domain.isEmpty, shouldObserveDomain(domain) else { return nil }
        let path = parts.count > 1 ? "/\(parts[1])" : "/"
        return (domain, path)
    }

    // MARK: - Sensitive Data Scrubbing

    /// Scrub sensitive data from any text before storage.
    /// Returns the scrubbed string with sensitive values replaced by [REDACTED].
    func scrubSensitiveData(_ text: String) -> String {
        var result = text
        let range = NSRange(result.startIndex..., in: result)

        // Order matters: most specific patterns first
        result = ssnPattern.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED:ssn]")
        let r2 = NSRange(result.startIndex..., in: result)
        result = creditCardPattern.stringByReplacingMatches(in: result, range: r2, withTemplate: "[REDACTED:card]")
        let r3 = NSRange(result.startIndex..., in: result)
        result = apiKeyPattern.stringByReplacingMatches(in: result, range: r3, withTemplate: "[REDACTED:key]")
        let r4 = NSRange(result.startIndex..., in: result)
        result = emailPattern.stringByReplacingMatches(in: result, range: r4, withTemplate: "[REDACTED:email]")
        let r5 = NSRange(result.startIndex..., in: result)
        result = phonePattern.stringByReplacingMatches(in: result, range: r5, withTemplate: "[REDACTED:phone]")

        return result
    }

    // MARK: - User Runtime Blacklist

    /// User says "stop watching [app]" → add bundle ID to runtime blacklist.
    var userBlacklistedApps: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: userBlacklistKey) ?? [])
    }

    func addToUserBlacklist(bundleId: String) {
        var list = UserDefaults.standard.stringArray(forKey: userBlacklistKey) ?? []
        if !list.contains(bundleId) {
            list.append(bundleId)
            UserDefaults.standard.set(list, forKey: userBlacklistKey)
        }
    }

    func removeFromUserBlacklist(bundleId: String) {
        var list = UserDefaults.standard.stringArray(forKey: userBlacklistKey) ?? []
        list.removeAll { $0 == bundleId }
        UserDefaults.standard.set(list, forKey: userBlacklistKey)
    }

    // MARK: - Full Event Filtering

    /// Returns true if this app observation should be stored.
    func shouldStore(appEvent: OEAppEvent) -> Bool {
        guard shouldObserveApp(bundleId: appEvent.bundleId) else { return false }
        guard shouldObserveWindowTitle(appEvent.windowTitle) else { return false }
        return true
    }

    /// Returns true if this URL observation should be stored.
    func shouldStore(urlEvent: OEURLEvent) -> Bool {
        guard shouldObserveApp(bundleId: urlEvent.browserBundleId) else { return false }
        guard shouldObserveDomain(urlEvent.domain) else { return false }
        return true
    }

    /// Returns true if this transition observation should be stored.
    func shouldStore(transitionEvent: OETransitionEvent) -> Bool {
        guard shouldObserveApp(bundleId: transitionEvent.fromApp) else { return false }
        guard shouldObserveApp(bundleId: transitionEvent.toApp) else { return false }
        guard shouldObserveWindowTitle(transitionEvent.fromContext) else { return false }
        guard shouldObserveWindowTitle(transitionEvent.toContext) else { return false }
        return true
    }
}
