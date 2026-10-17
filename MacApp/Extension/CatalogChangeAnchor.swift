import Foundation
import FileProvider

/// Generation-based alpha anchors expire once. Sequence anchors replay safely
/// and are independent of listing cursor invalidation or callback timing.
enum CatalogChangeAnchor {
    static func encode(_ sequence: Int64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("catalog-v2:\(sequence)".utf8))
    }

    static func decode(_ anchor: NSFileProviderSyncAnchor) throws -> Int64 {
        guard let text = String(data: anchor.rawValue, encoding: .utf8),
              text.hasPrefix("catalog-v2:"),
              let sequence = Int64(text.dropFirst(11)), sequence >= 0,
              encode(sequence) == anchor else { throw NSFileProviderError(.syncAnchorExpired) }
        return sequence
    }
}
