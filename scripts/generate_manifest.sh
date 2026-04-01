#!/bin/bash
# generate_manifest.sh — Generate a signed manifest for a release binary.
# Run after building the release DMG/app bundle.
#
# Usage: ./generate_manifest.sh <path-to-Executer.app> <version> <build> <private-key-hex>
# Example: ./generate_manifest.sh build/Executer.app 1.2.0 42 $(cat ~/.executer_signing_key)
#
# The private key should be a 64-char hex string (32 bytes Ed25519 private seed).
# Generate a keypair with:
#   swift -e 'import CryptoKit; let k = Curve25519.Signing.PrivateKey(); print("private: \(k.rawRepresentation.map{String(format:"%02x",$0)}.joined())"); print("public: \(k.publicKey.rawRepresentation.map{String(format:"%02x",$0)}.joined())")'

set -euo pipefail

APP_PATH="${1:?Usage: $0 <app-path> <version> <build> <private-key-hex>}"
VERSION="${2:?Missing version}"
BUILD="${3:?Missing build number}"
PRIVATE_KEY_HEX="${4:?Missing private key hex}"

BINARY="$APP_PATH/Contents/MacOS/Executer"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

# Compute SHA256
BINARY_SHA256=$(shasum -a 256 "$BINARY" | awk '{print $1}')
PUBLISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Version:    $VERSION"
echo "Build:      $BUILD"
echo "SHA256:     $BINARY_SHA256"
echo "Published:  $PUBLISHED_AT"

# Sign the payload: version|build|binary_sha256|published_at
PAYLOAD="${VERSION}|${BUILD}|${BINARY_SHA256}|${PUBLISHED_AT}"

# Use a small Swift script to sign with Ed25519
SIGNATURE=$(swift -e "
import CryptoKit
import Foundation
let keyHex = \"$PRIVATE_KEY_HEX\"
let bytes = stride(from: 0, to: keyHex.count, by: 2).map { i -> UInt8 in
    let start = keyHex.index(keyHex.startIndex, offsetBy: i)
    let end = keyHex.index(start, offsetBy: 2)
    return UInt8(keyHex[start..<end], radix: 16)!
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes))
let payload = \"$PAYLOAD\".data(using: .utf8)!
let sig = try key.signature(for: payload)
print(sig.map { String(format: \"%02x\", \$0) }.joined())
")

echo "Signature:  ${SIGNATURE:0:32}..."

# Generate manifest.json
cat > manifest.json <<EOF
{
  "version": "$VERSION",
  "build": "$BUILD",
  "binary_sha256": "$BINARY_SHA256",
  "published_at": "$PUBLISHED_AT",
  "signature": "$SIGNATURE"
}
EOF

echo ""
echo "Generated manifest.json"
echo "Upload with: gh release upload v$VERSION manifest.json --clobber"
