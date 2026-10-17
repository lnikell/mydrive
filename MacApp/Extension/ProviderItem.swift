import Foundation
import FileProvider
import UniformTypeIdentifiers
import MyDriveCore

/// Immutable metadata handed to File Provider. Hydration state belongs to macOS.
final class ProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let model: CatalogItem
    private let policy: OfflinePolicy
    private let displayName: String

    init(_ model: CatalogItem, policy: OfflinePolicy, displayName: String) {
        self.model = model
        self.policy = policy
        self.displayName = displayName
    }

    static func catalogID(_ identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? Catalog.rootID : identifier.rawValue
    }

    static func identifier(_ catalogID: String) -> NSFileProviderItemIdentifier {
        catalogID == Catalog.rootID ? .rootContainer : NSFileProviderItemIdentifier(catalogID)
    }

    var itemIdentifier: NSFileProviderItemIdentifier { Self.identifier(model.id) }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        Self.identifier(model.parentID ?? Catalog.rootID)
    }

    var filename: String { model.id == Catalog.rootID ? displayName : model.entry.name }

    var contentType: UTType {
        switch model.entry.kind {
        case .directory: .folder
        case .symbolicLink: .symbolicLink
        case .file:
            UTType(filenameExtension: (model.entry.name as NSString).pathExtension) ?? .data
        }
    }

    var capabilities: NSFileProviderItemCapabilities {
        model.entry.kind == .directory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        model.entry.kind == .directory ? [.userReadable, .userExecutable] : [.userReadable]
    }

    var documentSize: NSNumber? {
        model.entry.kind == .directory ? nil : NSNumber(value: model.entry.size)
    }

    var contentModificationDate: Date? { model.entry.modifiedAt }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data(model.entry.contentVersion.utf8),
            metadataVersion: Data(model.entry.metadataVersion.utf8))
    }

    var contentPolicy: NSFileProviderContentPolicy {
        policy == .keepAvailable ? .downloadEagerlyAndKeepDownloaded : .downloadLazily
    }

    // Every item enumerated by this read-only alpha already exists on the NAS.
    // Do not invent isDownloaded: macOS owns whether bytes are materialized.
    var isUploaded: Bool { true }
}
