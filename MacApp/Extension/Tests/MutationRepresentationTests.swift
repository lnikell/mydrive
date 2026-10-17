import FileProvider
import Foundation
import MyDriveCore

enum MutationRepresentationTests {
    static func run() async throws -> Int {
        for name in ["Document.rtfd", "Document.pages", "Application.app"] {
            let entry = RemoteEntry(name: name, kind: .directory, contentVersion: "c", metadataVersion: "m")
            let recognized = try MutationRepresentationPolicy.isPackageDirectory(entry)
            try mutationCheck(recognized, "Registered native package was not protected: " + name)
        }
        for name in ["Folder", "Folder.txt", "Folder.unregistered-mydrive-test"] {
            let entry = RemoteEntry(name: name, kind: .directory, contentVersion: "c", metadataVersion: "m")
            let recognized = try MutationRepresentationPolicy.isPackageDirectory(entry)
            try mutationCheck(!recognized, "An ordinary directory was mistaken for a package")
        }
        let regular = RemoteEntry(name: "File.rtfd", kind: .file, contentVersion: "c", metadataVersion: "m")
        try mutationCheck(try !MutationRepresentationPolicy.isPackageDirectory(regular), "Package-looking regular file was classified as a directory package")
        print("PASS representation policy protects registered directory packages without treating arbitrary extensions or regular files as packages")
        try await packageCallbacks()
        try await packageWrites()
        try await replacedPackage()
        try await unavailableRegistry()
        return 5
    }

    static func unavailableRegistry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = MutationPeer()
        let owner = ProviderMutations(catalog: try Catalog(databaseURL: root.appendingPathComponent("catalog.sqlite")),
            staging: try MutationStaging(root: root.appendingPathComponent("Mutations")),
            remote: MutationRemote(stat: { await peer.stat($0) }, mutate: { try await peer.mutate($0, $1, $2) }),
            checkActive: { try Task.checkCancellation() }, packageRegistryAvailable: { false })
        let original = await peer.seed(path: "Document.rtfd", bytes: Data(), directory: true)
        let scan = try await owner.catalog.beginScan()
        try await owner.catalog.stage([original.observation], in: scan)
        try await owner.catalog.completeScan(scan)
        let item = try await owner.catalog.children().items[0]
        do {
            try await owner.delete(id: item.id, contentVersion: Data(item.entry.contentVersion.utf8),
                metadataVersion: Data(item.entry.metadataVersion.utf8), progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Unavailable type lookup silently allowed directory deletion")
        } catch let error as NSError {
            try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue,
                              "Unavailable type lookup did not preserve the native item")
        }
        let operations = try await owner.catalog.replayableOperations(), calls = await peer.counts().2
        try mutationCheck(calls == 0 && operations.isEmpty, "Unavailable registry began a journal or remote mutation")
        let rename = try MutationInput(item: WriteTemplate(id: item.id, name: "Temporary", directory: true),
            fields: [.filename], contents: nil,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(item.entry.contentVersion.utf8),
                                                  metadataVersion: Data(item.entry.metadataVersion.utf8)))
        do {
            _ = try await owner.write(rename, create: false, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Unavailable type lookup silently allowed package safe-save rename")
        } catch let error as NSError {
            try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue,
                              "Unavailable write classifier lost preserving error semantics")
        }
        let finalCalls = await peer.counts().2, finalOperations = try await owner.catalog.replayableOperations()
        try mutationCheck(finalCalls == 0 && finalOperations.isEmpty,
                          "Unavailable write classifier began journal or RPC")
        print("PASS unavailable type lookup fails closed before journal creation or any destructive RPC")
    }

    private static func packageWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = MutationPeer(), owner = try MutationTests.fixture(root, peer)
        let package = await peer.seed(path: "Package.rtfd", bytes: Data(), directory: true)
        let leaf = await peer.seed(path: "Package.rtfd/TXT.rtf", bytes: Data("original".utf8))
        let ordinary = await peer.seed(path: "Ordinary.txt", bytes: Data("ordinary".utf8))
        let scan = try await owner.catalog.beginScan()
        try await owner.catalog.stage([package.observation, ordinary.observation], in: scan)
        try await owner.catalog.completeScan(scan)
        let folder = try await owner.catalog.child(named: "Package.rtfd", in: Catalog.rootID)!
        let file = try await owner.catalog.child(named: "Ordinary.txt", in: Catalog.rootID)!
        let children = try await owner.catalog.beginScan(of: folder.id)
        try await owner.catalog.stage([leaf.observation], in: children)
        try await owner.catalog.completeScan(children)
        let child = try await owner.catalog.children(of: folder.id).items[0]
        let payload = root.appendingPathComponent("edit")
        try Data("new local edit".utf8).write(to: payload)
        let newPackage = root.appendingPathComponent("New.rtfd")
        try FileManager.default.createDirectory(at: newPackage, withIntermediateDirectories: true)
        let newBytes = Data("complete new package remains local".utf8)
        try newBytes.write(to: newPackage.appendingPathComponent("TXT.rtf"))
        let base = NSFileProviderItemVersion(contentVersion: Data(folder.entry.contentVersion.utf8),
                                            metadataVersion: Data(folder.entry.metadataVersion.utf8))
        let cases: [(MutationInput, Bool)] = [
            // Exact observed TextEdit safe-save prefix: the original name is
            // still known when the first rename callback reaches the owner.
            (try MutationInput(item: WriteTemplate(id: folder.id, name: "Package.rtfd.sb-safe-save", directory: true),
                fields: [.filename], contents: nil, baseVersion: base), false),
            (try MutationInput(item: WriteTemplate(id: child.id, name: "Moved.rtf"),
                fields: [.filename, .parentItemIdentifier, .contents], contents: payload, baseVersion: base), false),
            (try MutationInput(item: WriteTemplate(id: file.id, parent: folder.id, name: "Ordinary.txt"),
                fields: [.parentItemIdentifier], contents: nil, baseVersion: base), false),
            (try MutationInput(item: WriteTemplate(id: "new-child", parent: folder.id, name: "New.txt"),
                fields: [.filename, .parentItemIdentifier, .contents], contents: payload), true),
            (try MutationInput(item: WriteTemplate(id: "new-package", name: "New.rtfd", directory: true),
                fields: [.filename, .parentItemIdentifier], contents: nil), true),
            // macOS supplies an actual directory for a package create. A
            // public.folder ACK would fail itemKindMismatch after publication.
            (try MutationInput(item: WriteTemplate(id: "new-package-contents", name: "New.rtfd", directory: true),
                fields: [.filename, .parentItemIdentifier, .contents], contents: newPackage,
                allowDirectoryContents: true), true)
        ]
        for (input, create) in cases {
            do {
                _ = try await owner.write(input, create: create, progress: Progress(totalUnitCount: 1))
                throw MutationTestFailure(message: "Package write bypassed read-only representation policy")
            } catch let error as NSError {
                try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue,
                                  "Package write did not retain dirty-item error semantics")
            }
        }
        let calls = await peer.counts().2, operations = try await owner.catalog.replayableOperations()
        let retained = await peer.hash("Package.rtfd/TXT.rtf"), source = await peer.stat("Package.rtfd")
        try mutationCheck(calls == 0 && operations.isEmpty && source == package && retained == MutationPeer.hash(Data("original".utf8)),
                          "Safe-save rename or package ancestry guard changed NAS bytes or started durable mutation")
        try mutationCheck(try Data(contentsOf: newPackage.appendingPathComponent("TXT.rtf")) == newBytes &&
            FileManager.default.contentsOfDirectory(atPath: owner.staging.root.path).isEmpty,
            "Refused package import discarded local bytes or started staging before representation qualification")
        // The refused rename must leave the original classified identity, so a
        // following delete cannot escape the same package protection.
        do {
            try await owner.delete(id: folder.id, contentVersion: Data(folder.entry.contentVersion.utf8),
                metadataVersion: Data(folder.entry.metadataVersion.utf8), progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Delete after refused safe-save rename changed original")
        } catch let error as NSError { try restoring(error, id: folder.id) }
        try mutationCheck(await peer.counts().2 == 0, "Safe-save rename/delete sequence reached a mutation")
        print("PASS package source, child and destination writes fail before staging/journal/RPC; safe-save rename cannot strip package protection")
    }

    private static func packageCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = MutationPeer(), owner = try MutationTests.fixture(root, peer)
        let directory = await peer.seed(path: "Document.rtfd", bytes: Data(), directory: true)
        let bytes = Data("package bytes must survive a later unsupported create".utf8)
        let leaf = await peer.seed(path: "Document.rtfd/TXT.rtf", bytes: bytes)
        let scan = try await owner.catalog.beginScan()
        try await owner.catalog.stage([directory.observation], in: scan)
        try await owner.catalog.completeScan(scan)
        let item = try await owner.catalog.children().items[0]
        let children = try await owner.catalog.beginScan(of: item.id)
        try await owner.catalog.stage([leaf.observation], in: children)
        try await owner.catalog.completeScan(children)
        let child = try await owner.catalog.children(of: item.id).items[0]
        let generation = try await owner.catalog.generation()
        let native = try DomainVersionSnapshot(.init(epoch: 0, contextID: UUID(), archive: DomainVersionSnapshot.initialArchive()))
        for selected in [item, child] {
            do {
                try await owner.delete(id: selected.id, contentVersion: Data(selected.entry.contentVersion.utf8),
                    metadataVersion: Data(selected.entry.metadataVersion.utf8), progress: Progress(totalUnitCount: 1))
                throw MutationTestFailure(message: "An ordinary package/descendant deletion was acknowledged")
            } catch let error as NSError {
                try restoring(error, id: selected.id)
            }
        }
        do {
            try await ProviderRecursiveDelete(mutations: owner, versions: native, published: {})
                .delete(id: item.id, contentVersion: Data(item.entry.contentVersion.utf8),
                    metadataVersion: Data(item.entry.metadataVersion.utf8),
                    context: .init(recursive: true, archive: nil, issuedContextID: nil), progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "A recursive package replacement deleted the original")
        } catch let error as NSError { try restoring(error, id: item.id) }
        let mutationCount = await peer.counts().2, retainedHash = await peer.hash("Document.rtfd/TXT.rtf")
        try mutationCheck(mutationCount == 0 && retainedHash == MutationPeer.hash(bytes),
                          "Package refusal reached a destructive RPC or changed original bytes")
        let unchanged = try await owner.catalog.generation() == generation, operations = try await owner.catalog.replayableOperations()
        try mutationCheck(unchanged && operations.isEmpty,
                          "Package refusal started a journal or changed Catalog before a safe representation existed")
        print("PASS ordinary, child-first and recursive package delete callbacks restore native items before any journal or destructive RPC")
    }

    private static func replacedPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = MutationPeer(), owner = try MutationTests.fixture(root, peer)
        let original = await peer.seed(path: "Document.pages", bytes: Data(), directory: true)
        let scan = try await owner.catalog.beginScan()
        try await owner.catalog.stage([original.observation], in: scan)
        try await owner.catalog.completeScan(scan)
        let item = try await owner.catalog.children().items[0]
        _ = await peer.seed(path: "Document.pages", bytes: Data(), directory: true)
        do {
            try await owner.delete(id: item.id, contentVersion: Data(item.entry.contentVersion.utf8),
                metadataVersion: Data(item.entry.metadataVersion.utf8), progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "A replacement package was rebound to an old Finder identity")
        } catch let error as NSError {
            try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue &&
                error.userInfo[NSFileProviderErrorItemKey] == nil, "Package refusal restored unverified replacement metadata")
        }
        try mutationCheck(await peer.counts().2 == 0, "Replaced package refusal made a mutation")
        print("PASS a replaced package fails closed without deleting it or restoring a false old Finder identity")
    }

    private static func restoring(_ error: NSError, id: String) throws {
        let item = error.userInfo[NSFileProviderErrorItemKey] as? any NSFileProviderItem
        try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.deletionRejected.rawValue &&
            item?.itemIdentifier == ProviderItem.identifier(id) && error.localizedDescription.contains("temporarily unavailable"),
                          "Package preservation lost native restoring metadata or its explicit limitation")
    }
}
