import CSQLite
import FileProvider
import Foundation
import MyDriveCore

enum MutationMetadataOnlyTests {
    private actor Calls {
        var remote = 0
        var checks = 0
        let cancelAt: Int?
        init(cancelAt: Int? = nil) { self.cancelAt = cancelAt }
        func called() { remote += 1 }
        func check() throws {
            checks += 1
            if checks == cancelAt { throw CancellationError() }
        }
    }

    private struct Fixture {
        let root: URL
        let owner: ProviderMutations
        let peer: MutationPeer
        let calls: Calls
        let package: CatalogItem
        let child: CatalogItem

        static func make(cancelAt: Int? = nil) async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let catalog = try Catalog(databaseURL: root.appendingPathComponent("catalog.sqlite"))
            let peer = MutationPeer(), calls = Calls(cancelAt: cancelAt)
            let owner = ProviderMutations(catalog: catalog, staging: try MutationStaging(root: root.appendingPathComponent("Mutations")),
                remote: MutationRemote(stat: { path in await calls.called(); return await peer.stat(path) },
                    mutate: { request, replay, progress in
                        await calls.called(); return try await peer.mutate(request, replay, progress)
                    }), checkActive: { try await calls.check() }, packageRegistryAvailable: { false })
            let package = await peer.seed(path: "Package.rtfd", bytes: Data(), directory: true)
            let child = await peer.seed(path: "Package.rtfd/TXT.rtf", bytes: Data("original".utf8))
            let top = try await catalog.beginScan()
            try await catalog.stage([package.observation], in: top)
            try await catalog.completeScan(top)
            guard let parent = try await catalog.child(named: package.name, in: Catalog.rootID) else {
                throw MutationTestFailure(message: "Missing package fixture")
            }
            let scan = try await catalog.beginScan(of: parent.id)
            try await catalog.stage([child.observation], in: scan)
            try await catalog.completeScan(scan)
            guard let item = try await catalog.child(named: child.name, in: parent.id) else {
                throw MutationTestFailure(message: "Missing child fixture")
            }
            return Self(root: root, owner: owner, peer: peer, calls: calls, package: parent, child: item)
        }

        func input(_ item: CatalogItem, fields: NSFileProviderItemFields, contents: URL? = nil,
                   directory: Bool? = nil) throws -> MutationInput {
            try MutationInput(item: WriteTemplate(id: item.id, parent: "stale-template-parent", name: "Old template name",
                directory: directory ?? (item.entry.kind == .directory)), fields: fields, contents: contents,
                baseVersion: NSFileProviderItemVersion(contentVersion: Data("old content".utf8), metadataVersion: Data("old metadata".utf8)))
        }

        func assertNoEffects(generation: Int64, operations: [JournalOperation] = []) async throws {
            try mutationCheck(await calls.remote == 0, "Metadata-only callback made a remote call")
            try mutationCheck(try await owner.catalog.generation() == generation, "Metadata-only callback changed Catalog")
            try mutationCheck(try await owner.catalog.replayableOperations() == operations, "Metadata-only callback changed pending mutation work")
        }
    }

    static func run() async throws -> Int {
        try await currentItemAndPendingFields()
        try await destructiveRequestsRemainGuarded()
        try await unavailableAndMalformedCurrent()
        try await cancellation()
        return 4
    }

    private static func currentItemAndPendingFields() async throws {
        let f = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sentinel = f.owner.staging.root.appendingPathComponent("independent-recovery")
        let recovery = Data("independent retained local bytes".utf8)
        try recovery.write(to: sentinel)
        let intent = JournalIntent(itemID: f.child.id, expectedVersion: f.child.entry.contentVersion,
            action: .rename(name: "Pending.rtf"), expectedMetadataVersion: f.child.entry.metadataVersion)
        _ = try await f.owner.catalog.enqueue(intent)
        _ = try await f.owner.catalog.transitionOperation(key: intent.idempotencyKey, from: .queued, to: .executing)
        _ = try await f.owner.catalog.transitionOperation(key: intent.idempotencyKey, from: .executing, to: .uncertain)
        let operations = try await f.owner.catalog.replayableOperations(), generation = try await f.owner.catalog.generation()
        let fields = NSFileProviderItemFields.lastUsedDate.union(.contentModificationDate)
            .union(NSFileProviderItemFields(rawValue: 1 << 30))
        for item in [f.package, f.child] {
            let input = try f.input(item, fields: fields)
            try mutationCheck(input.hasOnlyUnsupportedMetadata, "Unsupported metadata was routed as a write")
            for _ in 0..<2 {
                let progress = Progress(totalUnitCount: 1)
                let returned = try await f.owner.write(input, create: false, progress: progress)
                try mutationCheck(returned == item && input.pendingFields == fields && progress.completedUnitCount == 1,
                    "Unsupported package metadata did not return the live item with every changed field still pending")
            }
        }
        try await f.assertNoEffects(generation: generation, operations: operations)
        try mutationCheck(try Data(contentsOf: sentinel) == recovery &&
            FileManager.default.contentsOfDirectory(atPath: f.owner.staging.root.path) == [sentinel.lastPathComponent],
            "Metadata-only callback changed retained recovery files")
        print("PASS package and child metadata-only retries return current Catalog metadata, preserve pending fields and leave uncertain work untouched without any RPC")
    }

    private static func destructiveRequestsRemainGuarded() async throws {
        let f = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let generation = try await f.owner.catalog.generation()
        let payload = f.root.appendingPathComponent("dirty")
        let bytes = Data("dirty content remains local".utf8)
        try bytes.write(to: payload)
        for fields: NSFileProviderItemFields in [[.filename, .lastUsedDate], [.parentItemIdentifier], [.contents], [.contents, .lastUsedDate]] {
            try mutationCheck(try !f.input(f.child, fields: fields).hasOnlyUnsupportedMetadata,
                "Supported changed field was classified as metadata-only")
            try await expectFailure {
                _ = try await f.owner.write(f.input(f.child, fields: fields), create: false, progress: Progress(totalUnitCount: 1))
            }
        }
        let unchangedRename = try MutationInput(item: WriteTemplate(id: f.child.id, parent: f.package.id, name: f.child.entry.name),
            fields: [.filename, .parentItemIdentifier, .lastUsedDate], contents: nil)
        try await expectFailure {
            _ = try await f.owner.write(unchangedRename, create: false, progress: Progress(totalUnitCount: 1))
        }
        // Unexpected bytes are not metadata-only even when .contents is absent.
        try await expectFailure {
            _ = try await f.owner.write(f.input(f.child, fields: [.lastUsedDate], contents: payload),
                create: false, progress: Progress(totalUnitCount: 1))
        }
        try await expectFailure {
            let create = try MutationInput(item: WriteTemplate(id: "new-child", parent: f.package.id, name: "New.rtf"),
                fields: [.lastUsedDate], contents: nil)
            _ = try await f.owner.write(create, create: true, progress: Progress(totalUnitCount: 1))
        }
        try await f.assertNoEffects(generation: generation)
        try mutationCheck(try Data(contentsOf: payload) == bytes &&
            FileManager.default.contentsOfDirectory(atPath: f.owner.staging.root.path).isEmpty,
            "Destructive package request staged or discarded bytes before refusal")
        print("PASS supported filename/move/content flags, creates and unexpected contents remain guarded before staging/journal/RPC")
    }

    private static func unavailableAndMalformedCurrent() async throws {
        let f = try await Fixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let generation = try await f.owner.catalog.generation()
        try await expectFailure {
            _ = try await f.owner.write(f.input(f.child, fields: [.lastUsedDate], directory: true),
                create: false, progress: Progress(totalUnitCount: 1))
        }
        let missing = try MutationInput(item: WriteTemplate(id: "not-published", name: "Unknown.rtf"),
            fields: [.lastUsedDate], contents: nil)
        try await expectFailure {
            _ = try await f.owner.write(missing, create: false, progress: Progress(totalUnitCount: 1))
        }
        // A live row whose ancestor is unpublished is not usable current metadata.
        var database: OpaquePointer?
        guard sqlite3_open(f.root.appendingPathComponent("catalog.sqlite").path, &database) == SQLITE_OK else {
            throw MutationTestFailure(message: "Cannot open corruption fixture")
        }
        let changed = sqlite3_exec(database, "UPDATE items SET parent_id='missing-parent' WHERE name='TXT.rtf'", nil, nil, nil)
        sqlite3_close(database)
        try mutationCheck(changed == SQLITE_OK, "Cannot construct unpublished hierarchy fixture")
        try await expectFailure {
            _ = try await f.owner.write(f.input(f.child, fields: [.lastUsedDate]), create: false, progress: Progress(totalUnitCount: 1))
        }
        try await f.assertNoEffects(generation: generation)
        print("PASS metadata-only shortcut refuses kind changes, unknown current IDs and unpublished current hierarchy")
    }

    private static func cancellation() async throws {
        for at in [1, 2] {
            let f = try await Fixture.make(cancelAt: at)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let generation = try await f.owner.catalog.generation(), progress = Progress(totalUnitCount: 1)
            do {
                _ = try await f.owner.write(f.input(f.child, fields: [.lastUsedDate]), create: false, progress: progress)
                throw MutationTestFailure(message: "Cancelled metadata-only callback succeeded")
            } catch is CancellationError { }
            try mutationCheck(progress.completedUnitCount == 0, "Cancelled metadata callback completed progress")
            try await f.assertNoEffects(generation: generation)
        }
        print("PASS cancellation before work or after current Catalog lookup refuses completion without effects")
    }

    private static func expectFailure(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch is MutationTestFailure { throw MutationTestFailure(message: "Unexpected test fixture failure") }
        catch { return }
        throw MutationTestFailure(message: "Unsafe metadata-only shortcut succeeded")
    }
}
