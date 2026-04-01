import Foundation
import CryptoKit

/// Verifies the running binary against a signed manifest published on GitHub releases.
/// Only active for release builds. Network failures use a grace/strike system — never lock out.
actor ManifestVerifier {
    static let shared = ManifestVerifier()

    enum Result {
        case matched                    // Binary hash matches official release
        case mismatch(String)           // Hash differs — lockdown
        case signatureInvalid           // Manifest signature verification failed — lockdown
        case networkUnavailable         // Can't reach GitHub — grace period
        case noManifest                 // Release exists but no manifest asset (pre-manifest version)
    }

    struct Manifest: Codable {
        let version: String
        let build: String
        let binary_sha256: String
        let published_at: String
        let signature: String
    }

    /// GitHub repo for fetching releases.
    private let repoOwner = "allenwuzhouhan-web"
    private let repoName = "executer"

    /// Consecutive network failure count (resets on success).
    private var networkFailureStrikes = 0
    private let maxGraceStrikes = 3

    /// Verify the running binary against the GitHub release manifest.
    func verifyAgainstGitHub() async -> Result {
        guard AppModel.buildEnvironment == .release else {
            return .matched  // No-op for non-release
        }

        guard ManifestKeys.isConfigured else {
            print("[Manifest] Public key not configured — skipping verification")
            return .noManifest
        }

        let version = AppModel.version

        // Fetch the release for this version
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/tags/v\(version)"
        guard let url = URL(string: urlString) else {
            return .networkUnavailable
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Executer/\(version)", forHTTPHeaderField: "User-Agent")
        // Include device serial for installation tracking (not PII)
        request.setValue(DeviceSerial.serial, forHTTPHeaderField: "X-Executer-Serial")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await PinnedURLSession.shared.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return handleNetworkFailure()
            }

            if httpResponse.statusCode == 404 {
                // Release doesn't exist yet (or tag name differs)
                return .noManifest
            }

            guard httpResponse.statusCode == 200 else {
                return handleNetworkFailure()
            }

            // Parse the release JSON to find manifest.json asset
            guard let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = release["assets"] as? [[String: Any]] else {
                return handleNetworkFailure()
            }

            guard let manifestAsset = assets.first(where: { ($0["name"] as? String) == "manifest.json" }),
                  let downloadURL = manifestAsset["browser_download_url"] as? String,
                  let manifestURL = URL(string: downloadURL) else {
                return .noManifest
            }

            // Download the manifest
            var manifestRequest = URLRequest(url: manifestURL)
            manifestRequest.timeoutInterval = 10
            let (manifestData, _) = try await PinnedURLSession.shared.session.data(for: manifestRequest)

            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
                print("[Manifest] Failed to decode manifest JSON")
                return .noManifest
            }

            // Verify Ed25519 signature
            if !verifySignature(manifest: manifest, rawData: manifestData) {
                return .signatureInvalid
            }

            // Compare binary hash
            let localHash = computeLocalBinaryHash()
            guard let localHash = localHash else {
                print("[Manifest] Cannot compute local binary hash")
                return handleNetworkFailure()  // Treat as degraded — don't lock out
            }

            if localHash != manifest.binary_sha256 {
                return .mismatch("Local: \(localHash.prefix(16))..., Manifest: \(manifest.binary_sha256.prefix(16))...")
            }

            // Success — reset failure counter
            networkFailureStrikes = 0
            return .matched

        } catch {
            print("[Manifest] Network error: \(error.localizedDescription)")
            return handleNetworkFailure()
        }
    }

    // MARK: - Signature Verification

    private func verifySignature(manifest: Manifest, rawData: Data) -> Bool {
        guard let publicKey = ManifestKeys.publicKey else {
            print("[Manifest] No valid public key — cannot verify signature")
            return false
        }

        // The signature covers all fields except the signature field itself.
        // Reconstruct the signed payload: version|build|binary_sha256|published_at
        let payload = "\(manifest.version)|\(manifest.build)|\(manifest.binary_sha256)|\(manifest.published_at)"
        guard let payloadData = payload.data(using: .utf8) else { return false }

        // Decode the hex signature
        let sigBytes = ManifestKeys.publicKeyHex.isEmpty ? [] : hexToBytes(manifest.signature)
        guard sigBytes.count == 64 else {
            print("[Manifest] Invalid signature length: \(sigBytes.count)")
            return false
        }

        do {
            let signature = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey.rawRepresentation)
            return signature.isValidSignature(Data(sigBytes), for: payloadData)
        } catch {
            print("[Manifest] Signature verification error: \(error)")
            return false
        }
    }

    // MARK: - Binary Hash

    private func computeLocalBinaryHash() -> String? {
        guard let executablePath = Bundle.main.executablePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: executablePath)) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Network Failure Grace

    private func handleNetworkFailure() -> Result {
        networkFailureStrikes += 1
        if networkFailureStrikes >= maxGraceStrikes {
            print("[Manifest] WARNING: \(networkFailureStrikes) consecutive network failures — user should verify manually")
        }
        // NEVER lock out on network failure — only confirmed mismatch triggers lockdown
        return .networkUnavailable
    }

    // MARK: - Helpers

    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return bytes
    }
}
