import Foundation
import MyDriveCore
import UniformTypeIdentifiers

/// Directory packages need a qualified whole-package upload representation.
/// Until that exists, refuse their destructive callbacks before changing NAS
/// bytes; a later unsupported create cannot restore an earlier permanent delete.
enum MutationRepresentationPolicy {
    static func isPackageDirectory(_ entry: RemoteEntry,
                                   registryAvailable: @Sendable () -> Bool = registryIsAvailable) throws -> Bool {
        try isPackageDirectory(name: entry.name, kind: entry.kind, registryAvailable: registryAvailable)
    }

    static func isPackageDirectory(name: String, kind: ItemKind,
                                   registryAvailable: @Sendable () -> Bool = registryIsAvailable) throws -> Bool {
        guard kind == .directory else { return false }
        return try isPackageName(name, registryAvailable: registryAvailable)
    }

    private static func isPackageName(_ name: String, registryAvailable: @Sendable () -> Bool) throws -> Bool {
        let suffix = (name as NSString).pathExtension
        guard !suffix.isEmpty else { return false }
        guard registryAvailable() else {
            throw MutationInput.unsupported("File type information is temporarily unavailable. The NAS contents are preserved; try again after the drive has finished connecting.")
        }
        guard let type = UTType(filenameExtension: suffix, conformingTo: .package),
              !type.isDynamic else { return false }
        return type.conforms(to: .package)
    }

    static func registryIsAvailable() -> Bool {
        let known = UTType.plainText
        guard known.isDeclared, let suffix = known.preferredFilenameExtension,
              let resolved = UTType(filenameExtension: suffix), resolved.isDeclared, !resolved.isDynamic else { return false }
        return resolved.conforms(to: known)
    }

    static func containsPackageDirectory(path: String, kind: ItemKind,
                                         registryAvailable: @Sendable () -> Bool = registryIsAvailable) throws -> Bool {
        let components = path.split(separator: "/")
        let directories = kind == .directory ? components[...] : components.dropLast()
        return try directories.contains { name in
            try isPackageName(String(name), registryAvailable: registryAvailable)
        }
    }
}

extension ProviderMutations {
    func isPackageDirectory(_ entry: RemoteEntry) throws -> Bool {
        try MutationRepresentationPolicy.isPackageDirectory(entry, registryAvailable: packageRegistryAvailable)
    }

    func refuseUnsupportedPackageDeletion(id: String) async throws {
        guard let selected = try await catalog.item(id: id), !selected.isDeleted else { return }
        guard try await packageAncestor(id: id) != nil else { return }
        try await checkActive()
        guard let parentID = selected.parentID, let path = try await catalog.relativePath(id: id) else {
            throw MutationInput.unsupported("This package change cannot be verified safely. Its NAS contents are preserved.")
        }
        _ = try await preparation.verifiedParent(parentID)
        guard let current = try await remote.stat(path),
              let identity = selected.entry.objectIdentity, current.objectIdentity == identity,
              current.name.utf8.elementsEqual(selected.entry.name.utf8),
              current.directory == (selected.entry.kind == .directory), current.attributes & 0x400 == 0 else {
            throw MutationInput.unsupported("This package's NAS identity changed. Its current contents are preserved; refresh the folder before trying again.")
        }
        try await checkActive()
        throw try await deletionRejected(id: id, parentID: parentID, entry: current.observation,
            message: "Package deletion and replacement are temporarily unavailable to protect the original NAS files. Local edits are preserved.")
    }

    /// Native safe-save may rename a package to an unrecognized temporary name
    /// before deleting it. Refuse that first write, while its original Catalog
    /// ancestry still proves the representation requires whole-tree support.
    func refuseUnsupportedPackageWrite(_ input: MutationInput, create: Bool) async throws {
        try await checkActive()
        if !create, try await packageAncestor(id: input.id) != nil {
            throw packageWriteUnavailable()
        }
        if try await packageAncestor(id: input.parentID) != nil {
            throw packageWriteUnavailable()
        }
        if try MutationRepresentationPolicy.isPackageDirectory(name: input.filename, kind: input.kind,
            registryAvailable: packageRegistryAvailable) { throw packageWriteUnavailable() }
    }

    private func packageAncestor(id: String) async throws -> CatalogItem? {
        var currentID = id
        for _ in 0..<128 {
            try await checkActive()
            guard let item = try await catalog.item(id: currentID), !item.isDeleted else {
                // A delayed dirty callback has separate durable recovery. Do
                // not convert an unknown source into a namespace permission.
                if currentID == id { return nil }
                throw MutationInput.unsupported("The selected item's folder hierarchy needs a refresh. Its NAS contents are preserved.")
            }
            if try isPackageDirectory(item.entry) { return item }
            if item.id == Catalog.rootID { return nil }
            guard let parent = item.parentID else { break }
            currentID = parent
        }
        throw MutationInput.unsupported("The selected item's folder hierarchy needs a refresh. Its NAS contents are preserved.")
    }

    private func packageWriteUnavailable() -> NSError {
        MutationInput.unsupported("Package changes are temporarily unavailable to protect the original NAS files. Local edits are preserved.")
    }
}
