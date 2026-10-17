import Darwin
import Foundation

/// One portable SMB endpoint/share grammar for onboarding and legacy wire use.
/// It never includes the supplied input in errors or changes saved credentials.
struct SMBAddress: Equatable, Sendable {
    let endpoint: String
    let share: String

    init(server: String, share manualShare: String) throws {
        guard server.utf8.count <= 4096, manualShare.utf8.count <= 255 else { throw SMBAddressError.tooLong }
        guard !Self.controls(server), !Self.controls(manualShare) else { throw SMBAddressError.invalidInput }
        let input = server.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { throw SMBAddressError.serverRequired }
        var authority = input, embedded: String?
        if input.lowercased().hasPrefix("smb://") {
            let value = String(input.dropFirst(6))
            guard !value.contains("@"), !value.contains("?"), !value.contains("#"), !value.contains("\\") else {
                throw SMBAddressError.invalidURL
            }
            if let slash = value.firstIndex(of: "/") {
                authority = String(value[..<slash])
                var encoded = String(value[value.index(after: slash)...])
                if encoded.hasSuffix("/") {
                    encoded.removeLast()
                    guard !encoded.isEmpty else { throw SMBAddressError.invalidURL }
                }
                guard !encoded.contains("/"), let decoded = encoded.removingPercentEncoding else { throw SMBAddressError.invalidURL }
                if !decoded.isEmpty { embedded = decoded }
            } else { authority = value }
        } else if input.contains("://") || input.contains("/") { throw SMBAddressError.invalidURL }
        endpoint = try Self.endpoint(authority)
        if let embedded, !manualShare.isEmpty, !embedded.utf8.elementsEqual(manualShare.utf8) { throw SMBAddressError.shareConflict }
        let resolved = embedded ?? manualShare
        guard !resolved.trimmingCharacters(in: .whitespaces).isEmpty else { throw SMBAddressError.shareRequired }
        guard resolved.utf8.count <= 255 else { throw SMBAddressError.tooLong }
        guard !Self.controls(resolved), resolved != ".", resolved != "..",
              !resolved.contains("/"), !resolved.contains("\\"), !resolved.contains(":") else { throw SMBAddressError.invalidShare }
        share = resolved
    }

    private static func endpoint(_ value: String) throws -> String {
        var host: String, port = "445"
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { throw SMBAddressError.invalidServer }
            host = String(value[value.index(after: value.startIndex)..<end])
            let suffix = String(value[value.index(after: end)...])
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { throw SMBAddressError.invalidServer }
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":") else { throw SMBAddressError.invalidServer }
                port = String(suffix.dropFirst())
            }
            host = "[" + host.lowercased() + "]"
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { throw SMBAddressError.invalidServer }
            host = String(parts[0]).lowercased()
            if parts.count == 2 { port = String(parts[1]) }
            let dns = host.hasSuffix(".") ? String(host.dropLast()) : host
            let labels = dns.split(separator: ".", omittingEmptySubsequences: false)
            guard !dns.isEmpty, dns.utf8.count <= 253, labels.allSatisfy({ label in
                let bytes = Array(label.utf8)
                return (1...63).contains(bytes.count) && bytes.first.map(hostBoundary) == true &&
                    bytes.last.map(hostBoundary) == true && bytes.allSatisfy { hostBoundary($0) || $0 == 45 }
            }) else { throw SMBAddressError.invalidServer }
            if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
                var address = in_addr()
                guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { throw SMBAddressError.invalidServer }
            }
        }
        guard !port.isEmpty, port.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt16(port), number > 0 else { throw SMBAddressError.invalidPort }
        return host + ":" + String(number)
    }

    private static func alphaNumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
    private static func hostBoundary(_ byte: UInt8) -> Bool { alphaNumeric(byte) || byte == 95 }
    private static func controls(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }
}

enum SMBAddressError: LocalizedError, Sendable {
    case serverRequired, shareRequired, invalidServer, invalidPort, invalidShare, invalidURL, shareConflict, invalidInput, tooLong
    var errorDescription: String? {
        switch self {
        case .serverRequired: "Enter the NAS server name or IP address."
        case .shareRequired: "Enter a share name, or include it in an smb:// server URL."
        case .invalidServer: "Enter a valid NAS hostname or IP address. Put IPv6 addresses in brackets."
        case .invalidPort: "The server port must be a number from 1 to 65535."
        case .invalidShare: "Enter one share name without path separators or traversal components."
        case .invalidURL: "Use smb://server/share without login details, a deeper path, query or fragment."
        case .shareConflict: "The share in the server URL differs from the Share field. Use the same share in both."
        case .invalidInput: "Server and share names cannot contain control characters."
        case .tooLong: "The server address or share name is too long."
        }
    }
}
