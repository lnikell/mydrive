import CryptoKit
import Foundation

// This executable never prints the seed. The configured public key is public;
// exported private key bytes arrive only through stdin, with a strict bound.
do {
    guard CommandLine.arguments.count == 2,
          let expected = Data(base64Encoded: CommandLine.arguments[1]), expected.count == 32 else { exit(1) }
    var encoded = Data()
    defer { encoded.resetBytes(in: 0..<encoded.count) }
    while let chunk = try FileHandle.standardInput.read(upToCount: 1025 - encoded.count), !chunk.isEmpty {
        encoded.append(chunk)
        guard encoded.count <= 1024 else { exit(1) }
    }
    guard encoded.count <= 1024, let text = String(data: encoded, encoding: .utf8),
          var bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          bytes.count == 32 || bytes.count == 64 else { exit(1) }
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes.prefix(32))
    exit(key.publicKey.rawRepresentation == expected ? 0 : 1)
} catch { exit(1) }
