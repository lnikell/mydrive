import Foundation
import FileProvider
import UniformTypeIdentifiers
import MyDriveCore

/// Immutable metadata handed to File Provider. Hydration state belongs to macOS.
final class ProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let model: CatalogItem
    private let policy: OfflinePolicy
    private let displayName: String
    private let access: ProviderItemAccess

    init(_ model: CatalogItem, policy: OfflinePolicy, displayName: String, access: ProviderItemAccess) {
        self.model = model
        self.policy = policy
        self.displayName = displayName
        self.access = access
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
        guard access == .readWrite else {
            return model.entry.kind == .directory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        }
        switch model.entry.kind {
        case .directory:
            var value: NSFileProviderItemCapabilities = [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
            if model.id != Catalog.rootID { value.formUnion([.allowsRenaming, .allowsReparenting, .allowsDeleting]) }
            return value
        case .file: return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        case .symbolicLink: return [.allowsReading]
        }
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        if access == .readOnly {
            return model.entry.kind == .directory ? [.userReadable, .userExecutable] : [.userReadable]
        }
        return switch model.entry.kind {
        case .directory: [.userReadable, .userWritable, .userExecutable]
        case .file: [.userReadable, .userWritable]
        case .symbolicLink: [.userReadable]
        }
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

    // Only verified remote commits are ever published as uploaded items.
    // Do not invent isDownloaded: macOS owns whether bytes are materialized.
    var isUploaded: Bool { true }
}
