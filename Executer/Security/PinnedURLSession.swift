import Foundation
import Security
import CryptoKit

/// URLSession with certificate pinning via SPKI (SubjectPublicKeyInfo) hash validation.
/// Pins the public key (not the certificate) so that certificate rotation doesn't break pinning.
/// Unknown domains pass through with standard TLS validation — only pinned domains are strict.
final class PinnedURLSession: NSObject, URLSessionDelegate {
    static let shared = PinnedURLSession()

    /// The pinned URLSession — use this instead of URLSession.shared for network calls.
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Whether pinning is active (release builds only).
    private var pinningEnabled: Bool {
        AppModel.buildEnvironment == .release
    }

    /// SPKI SHA256 pin hashes per domain.
    /// Each domain can have multiple pins (leaf + intermediate backup).
    /// To get a pin: `openssl s_client -connect api.anthropic.com:443 | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`
    private let pinnedHashes: [String: Set<String>] = [
        // Anthropic (Claude API)
        "api.anthropic.com": [
            // These are placeholder pins — replace with actual SPKI hashes before shipping.
            // Run the openssl command above to get real values.
            "PLACEHOLDER_ANTHROPIC_LEAF_PIN",
            "PLACEHOLDER_ANTHROPIC_INTERMEDIATE_PIN",
        ],
        // DeepSeek
        "api.deepseek.com": [
            "PLACEHOLDER_DEEPSEEK_PIN",
        ],
        // GitHub API (updates + manifest)
        "api.github.com": [
            "PLACEHOLDER_GITHUB_PIN",
        ],
    ]

    /// Whether real pins have been configured (not placeholders).
    private var hasRealPins: Bool {
        pinnedHashes.values.contains { pins in
            pins.contains { !$0.hasPrefix("PLACEHOLDER_") }
        }
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Only pin known domains in release mode with real pins configured
        guard pinningEnabled, hasRealPins, let expectedPins = pinnedHashes[host] else {
            // Unknown domain or dev build — use standard TLS validation
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the server trust first (standard TLS validation)
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            print("[Pinning] TLS validation failed for \(host): \(error?.localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Extract the server's public key and compute SPKI hash
        let certificateCount = SecTrustGetCertificateCount(serverTrust)
        var matched = false

        for i in 0..<certificateCount {
            guard let certificate = SecTrustGetCertificateAtIndex(serverTrust, i) else { continue }

            // Get the public key from the certificate
            guard let publicKey = SecCertificateCopyKey(certificate) else { continue }

            // Export the public key as DER data
            var exportError: Unmanaged<CFError>?
            guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
                continue
            }

            // SHA256 hash of the public key DER
            let hash = SHA256.hash(data: publicKeyData)
            let hashBase64 = Data(hash).base64EncodedString()

            if expectedPins.contains(hashBase64) {
                matched = true
                break
            }
        }

        if matched {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            print("[Pinning] SPKI pin mismatch for \(host) — rejecting connection")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - Dashboard

    static func statusSummary() -> String {
        let instance = PinnedURLSession.shared
        if !instance.pinningEnabled {
            return "Disabled (non-release build)"
        }
        if !instance.hasRealPins {
            return "Not configured (placeholder pins)"
        }
        let domains = instance.pinnedHashes.keys.sorted().joined(separator: ", ")
        return "Active for: \(domains)"
    }
}
