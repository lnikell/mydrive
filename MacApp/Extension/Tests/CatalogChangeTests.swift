import FileProvider
import Foundation
import MyDriveCore

enum CatalogChangeTests {
    static func run() throws -> Int {
        for sequence: Int64 in [0, 1, Int64.max] {
            guard try CatalogChangeAnchor.decode(CatalogChangeAnchor.encode(sequence)) == sequence else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        for text in ["catalog-v1:1", "catalog-v2:-1", "catalog-v2:01", "catalog-v2:+1", "catalog-v2:9223372036854775808", ""] {
            do {
                _ = try CatalogChangeAnchor.decode(NSFileProviderSyncAnchor(Data(text.utf8)))
                throw CocoaError(.fileReadCorruptFile)
            } catch let error as NSFileProviderError {
                guard error.code == .syncAnchorExpired else { throw error }
            }
        }
        let expired = ProviderErrors.translate(ChangeFeedError.invalidAnchor) as NSError
        guard expired.domain == NSFileProviderErrorDomain && expired.code == NSFileProviderError.syncAnchorExpired.rawValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let unsupported = ProviderErrors.translate(SMBClientError.unsupportedFeature) as NSError
        guard unsupported.domain == NSCocoaErrorDomain && unsupported.code == CocoaError.featureUnsupported.rawValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("PASS sequence anchor migration, strict decoding, and retained-history expiration mapping")
        return 1
    }
}
