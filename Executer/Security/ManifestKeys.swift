import Foundation
import CryptoKit

/// Ed25519 public key for verifying release manifest signatures.
/// The private key NEVER leaves the release machine and is NEVER committed to the repo.
enum ManifestKeys {
    /// Ed25519 public key bytes (32 bytes) for manifest signature verification.
    /// Replace with the real public key when setting up the release pipeline.
    /// Generate keypair with: `swift -e "import CryptoKit; let key = Curve25519.Signing.PrivateKey(); print(key.publicKey.rawRepresentation.map { String(format: \"%02x\", $0) }.joined())"`
    static let publicKeyHex = "0000000000000000000000000000000000000000000000000000000000000000"  // TODO: Replace with real key

    /// Parsed public key for signature verification.
    static var publicKey: Curve25519.Signing.PublicKey? {
        guard isConfigured else { return nil }
        let bytes = hexToBytes(publicKeyHex)
        guard bytes.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: Data(bytes))
    }

    /// Whether the real public key has been configured (not the placeholder zeros).
    static var isConfigured: Bool {
        publicKeyHex != String(repeating: "0", count: 64)
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
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
