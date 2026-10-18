import FileProvider
import Foundation
import UniformTypeIdentifiers
import MyDriveCore
import CryptoKit

/// Snapshot Objective-C templates before handing the operation to a task.
/// These are requested values, never a claim that their bytes are uploaded.
struct MutationInput: Sendable {
    let id: String
    let parentID: String
    let filename: String
    let kind: ItemKind
    let fields: NSFileProviderItemFields
    let contents: URL?
    let baseContent: Data?
    let baseMetadata: Data?

    init(item: any NSFileProviderItem, fields: NSFileProviderItemFields,
         contents: URL?, baseVersion: NSFileProviderItemVersion? = nil,
         allowDirectoryContents: Bool = false) throws {
        id = ProviderItem.catalogID(item.itemIdentifier)
        parentID = ProviderItem.catalogID(item.parentItemIdentifier)
        filename = item.filename
        let type = item.contentType ?? .data
        if type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) {
            throw Self.unsupported("Symbolic links and Finder aliases cannot be uploaded yet.")
        }
        kind = type.conforms(to: .directory) || type.conforms(to: .folder) || type.conforms(to: .package)
            ? .directory : .file
        guard kind != .directory || contents == nil || allowDirectoryContents else {
            throw Self.unsupported("Whole-folder replacement cannot be uploaded safely yet. Its local contents are preserved.")
        }
        self.fields = fields; self.contents = contents
        baseContent = baseVersion?.contentVersion
        baseMetadata = baseVersion?.metadataVersion
        if baseVersion == nil || fields.contains(.filename) { try Self.validateName(filename) }
    }

    private init(id: String, parentID: String, filename: String, kind: ItemKind,
                 fields: NSFileProviderItemFields, contents: URL?, baseContent: Data?, baseMetadata: Data?) {
        self.id = id; self.parentID = parentID; self.filename = filename; self.kind = kind
        self.fields = fields; self.contents = contents
        self.baseContent = baseContent; self.baseMetadata = baseMetadata
    }

    func mergingUnchanged(_ current: CatalogItem) throws -> MutationInput {
        guard current.entry.kind == kind else { throw Self.unsupported("Changing an item's file type is not supported.") }
        return MutationInput(id: id,
            parentID: fields.contains(.parentItemIdentifier) ? parentID : current.parentID ?? Catalog.rootID,
            filename: fields.contains(.filename) ? filename : current.entry.name,
            kind: kind, fields: fields, contents: contents,
            baseContent: baseContent, baseMetadata: baseMetadata)
    }

    static let supportedFields: NSFileProviderItemFields = [.filename, .parentItemIdentifier, .contents]

    var hasOnlyUnsupportedMetadata: Bool {
        contents == nil && fields.intersection(Self.supportedFields).isEmpty
    }

    var pendingFields: NSFileProviderItemFields { fields.subtracting(Self.supportedFields) }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    static func unsupported(_ message: String) -> NSError {
        NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Includes only the OS request and bytes. Mutable Catalog observations and
    /// temporary filenames must not turn a crash replay into another upload.
    func operationID(create: Bool, payload: StagedPayload?) -> UUID {
        var data = Data()
        func add(_ bytes: Data?) {
            guard let bytes else { data.append(Data("-;".utf8)); return }
            data.append(Data("\(bytes.count):".utf8)); data.append(bytes)
        }
        for value in [create ? "create" : "modify", id,
                      create || fields.contains(.parentItemIdentifier) ? parentID : "",
                      create || fields.contains(.filename) ? filename : "",
                      kind.rawValue, String(fields.intersection(Self.supportedFields).rawValue), payload?.sha256 ?? ""] {
            add(Data(value.utf8))
        }
        add(baseContent); add(baseMetadata)
        return Self.uuid(for: data)
    }

    static func deletionID(id: String, content: Data, metadata: Data) -> UUID {
        var data = Data("delete-v1".utf8)
        for value in [Data(id.utf8), content, metadata] {
            data.append(Data("\(value.count):".utf8)); data.append(value)
        }
        return uuid(for: data)
    }

    static func recursiveDeletionID(id: String, content: Data, metadata: Data, context: UUID?) -> UUID {
        derivedID(deletionID(id: id, content: content, metadata: metadata),
                  "recursive:" + (context?.uuidString.lowercased() ?? "unknown"))
    }

    static func derivedID(_ operationID: UUID, _ purpose: String) -> UUID {
        uuid(for: Data((operationID.uuidString.lowercased() + ":" + purpose).utf8))
    }

    static func uuid(for data: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
