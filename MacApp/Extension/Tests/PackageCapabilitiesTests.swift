import FileProvider
import Foundation
import MyDriveCore
import UniformTypeIdentifiers

private actor ProjectionPeer {
    var values: [String: CatalogItem]
    var calls: [String: Int] = [:]
    init(_ values: [CatalogItem]) { self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }) }
    func item(_ id: String) -> CatalogItem? { calls[id, default: 0] += 1; return values[id] }
    func count(_ id: String) -> Int { calls[id] ?? 0 }
    func total() -> Int { calls.values.reduce(0, +) }
}

@MainActor enum PackageCapabilitiesTests {
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "PackageCapabilitiesTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func model(_ id: String, _ parent: String?, _ name: String,
                              _ kind: ItemKind = .directory, deleted: Bool = false) -> CatalogItem {
        CatalogItem(id: id, parentID: parent, entry: RemoteEntry(name: name, kind: kind,
            contentVersion: "content-\(id)", metadataVersion: "metadata-\(id)", size: kind == .file ? 23 : 0),
            isDeleted: deleted)
    }

    private static var root: CatalogItem { model(Catalog.rootID, nil, "") }

    private static func projected(_ models: [CatalogItem], peer: ProjectionPeer,
                                  registry: @escaping @Sendable () -> Bool = MutationRepresentationPolicy.registryIsAvailable
    ) async throws -> [ProviderItem] {
        try await ProviderItemProjection.items(models, displayName: "Displayed.rtfd",
            lookup: { await peer.item($0) }, policy: { _ in .onDemand }, registryAvailable: registry)
    }

    private static func readOnly(_ item: ProviderItem) throws {
        try check(item.capabilities == [.allowsReading], "Protected item advertises a write or namespace action")
        try check(!item.fileSystemFlags.contains(.userWritable), "Protected item advertises writable permissions")
        try check(item.fileSystemFlags.contains(.userReadable), "Protected item became unreadable")
        if item.model.entry.kind == .directory {
            try check(item.capabilities.contains(.allowsContentEnumerating), "Protected directory cannot be enumerated")
        }
        try check(item.fileSystemFlags.contains(.userExecutable) == (item.model.entry.kind == .directory),
            "Directory traversal or ordinary file execution flags changed")
    }

    static func run(requiresRegistry: Bool = true) async throws -> Int {
        try await ordinaryBatchAndRoot()
        try await malformedAndUnavailable()
        try await depthAndMemoBounds()
        try await cancellationAndErrors()
        try await committedCancellation()
        guard requiresRegistry else { return 5 }
        try check(MutationRepresentationPolicy.registryIsAvailable() &&
            MutationRepresentationPolicy.isPackageDirectory(name: "Document.rtfd", kind: .directory),
            "Actual package registry is unavailable; run this focused binary in the normal app context")
        try await packagesAndNoninheritance()
        try await currentCatalogMoves()
        return 7
    }

    private static func ordinaryBatchAndRoot() async throws {
        let parent = model("parent", Catalog.rootID, "Ordinary")
        let leaves = (0..<128).map { model("file-\($0)", parent.id, "file-\($0)", .file) }
        let peer = ProjectionPeer([root, parent])
        let items = try await projected(leaves, peer: peer)
        try check(items.count == 128 && items.allSatisfy { $0.capabilities.contains(.allowsWriting) &&
            $0.capabilities.contains(.allowsRenaming) && $0.fileSystemFlags.contains(.userWritable) },
            "Ordinary files lost their existing writable projection")
        let parentCalls = await peer.count(parent.id), rootCalls = await peer.count(Catalog.rootID), total = await peer.total()
        try check(parentCalls == 1 && rootCalls == 1 && total == 2,
            "A flat page repeated shared ancestor SQL lookups")
        let rootItem = try await projected([root], peer: peer)[0]
        try check(rootItem.filename == "Displayed.rtfd" && rootItem.capabilities.contains(.allowsAddingSubItems) &&
            !rootItem.capabilities.contains(.allowsRenaming), "Synthetic root display name changed its namespace permissions")
        print("PASS128 ordinary files share two ancestor lookups; valid root remains writable for children")
    }

    private static func packagesAndNoninheritance() async throws {
        let package = model("package", Catalog.rootID, "Document.rtfd")
        let inner = model("inner", package.id, "Nested")
        let child = model("child", inner.id, "TXT.rtf", .file)
        let suffixFile = model("suffix-file", Catalog.rootID, "A.rtfd", .file)
        let textFolder = model("text-folder", Catalog.rootID, "Folder.txt")
        let dynamic = model("dynamic", Catalog.rootID, "Folder.mydriveUnknownType")
        let peer = ProjectionPeer([root, package, inner, child])
        let items = try await projected([package, inner, child, suffixFile, textFolder, dynamic], peer: peer)
        for item in items.prefix(3) { try readOnly(item) }
        try check(items[0].contentType == .folder && items[1].contentType == .folder &&
            items[2].itemVersion.contentVersion == Data(child.entry.contentVersion.utf8) &&
            items[2].documentSize == 23, "Read-only access changed content type/version/size")
        for item in items.suffix(3) { try check(item.capabilities.contains(
            item.model.entry.kind == .directory ? .allowsAddingSubItems : .allowsWriting),
            "A regular file suffix or non-package directory was classified as a protected package") }
        let single = try await projected([child], peer: peer)[0]
        try check(single.capabilities == items[2].capabilities && single.fileSystemFlags == items[2].fileSystemFlags,
            "Single lookup and batch descendant restrictions differ")
        print("PASS recognized package and every descendant are explicitly read-only; capabilities are not assumed inherited")
    }

    private static func malformedAndUnavailable() async throws {
        let missing = model("missing", "absent", "Leaf", .file)
        let deleted = model("deleted", Catalog.rootID, "Deleted", deleted: true)
        let deletedChild = model("deleted-child", deleted.id, "Leaf", .file)
        let wrongKind = model("not-parent", Catalog.rootID, "File", .file)
        let wrongChild = model("wrong-child", wrongKind.id, "Leaf", .file)
        let cycleA = model("cycle-a", "cycle-b", "A"), cycleB = model("cycle-b", "cycle-a", "B")
        let dotted = model("dotted", Catalog.rootID, "Unknown.ext")
        let dottedChild = model("dotted-child", dotted.id, "Leaf", .file)
        let peer = ProjectionPeer([root, deleted, wrongKind, cycleA, cycleB, dotted])
        let items = try await projected([missing, deletedChild, wrongChild, cycleA, dottedChild], peer: peer, registry: { false })
        for item in items { try readOnly(item) }
        let rootValue = root
        let mismatch = try await ProviderItemProjection.items([missing], displayName: "Drive",
            lookup: { _ in rootValue }, policy: { _ in .onDemand })
        try readOnly(mismatch[0])
        print("PASS missing/deleted/cyclic/wrong-kind ancestry and unavailable type registry cannot enable writes")
    }

    private static func depthAndMemoBounds() async throws {
        var chain = [root]
        for i in 1...128 { chain.append(model("depth-\(i)", i == 1 ? Catalog.rootID : "depth-\(i-1)", "D\(i)")) }
        let p2 = model("other-2", Catalog.rootID, "Other2"), p3 = model("other-3", Catalog.rootID, "Other3")
        let a = model("a", p2.id, "A", .file), b = model("b", p3.id, "B", .file), c = model("c", p3.id, "C", .file)
        let peer = ProjectionPeer(chain + [p2, p3])
        let items = try await projected([chain[128], chain[127], a, b, c], peer: peer)
        try readOnly(items[0])
        try check(items.dropFirst().allSatisfy { $0.capabilities.contains(.allowsWriting) },
            "Depth exhaustion poisoned a shorter valid chain or a page memo bypassed the guard's depth bound")
        try check(await peer.count(p3.id) == 2, "Ancestor memo exceeded its128 fetched-node bound")
        print("PASS128-node ancestry limit matches guard and shared memo stays bounded without stale access decisions")
    }

    private static func cancellationAndErrors() async throws {
        let child = model("child", "parent", "Leaf", .file)
        let rootValue = root
        let task = Task { @MainActor in
            try await ProviderItemProjection.items([child], displayName: "Drive", lookup: { _ in
                withUnsafeCurrentTask { $0?.cancel() }; return rootValue
            }, policy: { _ in .onDemand })
        }
        do { _ = try await task.value; throw CocoaError(.fileReadUnknown) }
        catch is CancellationError { }
        let policyCancelled = Task { @MainActor in
            try await ProviderItemProjection.items([rootValue], displayName: "Drive", lookup: { _ in nil }, policy: { _ in
                withUnsafeCurrentTask { $0?.cancel() }; return .onDemand
            })
        }
        do { _ = try await policyCancelled.value; throw CocoaError(.fileReadUnknown) }
        catch is CancellationError { }
        do {
            _ = try await ProviderItemProjection.items([child], displayName: "Drive",
                lookup: { _ in throw CatalogError.invalidEntry }, policy: { _ in .onDemand })
            throw CocoaError(.fileReadUnknown)
        } catch let error as CatalogError { try check(error == .invalidEntry, "Catalog error changed") }
        print("PASS cancellation after ancestry/policy await and Catalog failures propagate without a writable fallback")
    }

    private static func committedCancellation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(databaseURL: folder.appendingPathComponent("catalog.sqlite"))
        let scan = try await catalog.beginScan()
        try await catalog.stage([model("ignored", nil, "Ordinary", .file).entry], in: scan)
        try await catalog.completeScan(scan)
        guard let item = try await catalog.child(named: "Ordinary", in: Catalog.rootID) else { throw CatalogError.invalidEntry }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProviderItemProjection.committedItem(item, catalog: catalog, displayName: "Drive")
        }
        let projected = try await task.value
        try check(projected.model == item && projected.capabilities.contains(.allowsWriting) &&
            projected.itemVersion.contentVersion == Data(item.entry.contentVersion.utf8),
            "Cancelled postcommit projection failed or synthesized a different accepted item")
        print("PASS committed-item projection keeps the accepted Catalog result despite callback cancellation")
    }

    private static func currentCatalogMoves() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(databaseURL: folder.appendingPathComponent("catalog.sqlite"))
        let scan = try await catalog.beginScan()
        try await catalog.stage([model("ignored", nil, "Package.rtfd").entry,
            model("ignored", nil, "Ordinary").entry], in: scan)
        try await catalog.completeScan(scan)
        guard let package = try await catalog.child(named: "Package.rtfd", in: Catalog.rootID),
              let ordinary = try await catalog.child(named: "Ordinary", in: Catalog.rootID) else { throw CatalogError.invalidEntry }
        let children = try await catalog.beginScan(of: package.id)
        try await catalog.stage([model("ignored", nil, "TXT.rtf", .file).entry], in: children)
        try await catalog.completeScan(children)
        guard let child = try await catalog.child(named: "TXT.rtf", in: package.id) else { throw CatalogError.invalidEntry }
        try readOnly(try await ProviderItemProjection.item(child, catalog: catalog, displayName: "Drive"))
        let intent = JournalIntent(itemID: child.id, expectedVersion: child.entry.contentVersion,
            action: .update(parentID: ordinary.id, name: child.entry.name), expectedMetadataVersion: child.entry.metadataVersion)
        let operation = try await catalog.enqueue(intent)
        try await catalog.transitionOperation(key: operation.intent.idempotencyKey, from: .queued, to: .executing)
        let moved = try await catalog.commitMutation(key: operation.intent.idempotencyKey,
            upserts: [.init(id: child.id, parentID: ordinary.id, entry: child.entry)], tombstones: []).items[0]
        let projected = try await ProviderItemProjection.item(moved, catalog: catalog, displayName: "Drive")
        try check(projected.capabilities.contains(.allowsWriting), "A new projection retained the old package ancestry")
        let destination = try await ProviderItemProjection.item(package, catalog: catalog, displayName: "Drive")
        try check(!destination.capabilities.contains(.allowsAddingSubItems), "Package advertises permission to move ordinary items into it")
        print("PASS real Catalog move reprojects current ancestry; package destination rejects adding children")
    }
}
