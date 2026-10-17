import FileProvider
import Foundation
import MyDriveCore

enum TreeImportTests {
    static func run() async throws -> Int {
        try await publishedGraph()
        try await readbackRestart()
        try await lostPublication()
        try await parentFence()
        try await allocatedOwnerRestart()
        try await staleChildMaintenance()
        try await preflightRecovery()
        return 7
    }

    struct Fixture {
        let root: URL
        let source: URL
        let peer: MutationPeer
        let owner: ProviderMutations
        let input: MutationInput
    }

    static func fixture(wide: Bool = false, probe: TreeFrontierProbe? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Local.rtfd")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
        try Data("the complete local package".utf8).write(to: source.appendingPathComponent("TXT.rtf"))
        try Data([0, 1, 2, 255]).write(to: source.appendingPathComponent("Nested/Bytes.bin"))
        if wide {
            for index in 0..<100 {
                try Data("small file \(index)".utf8).write(to: source.appendingPathComponent(String(format: "Small-%03d.txt", index)))
            }
        }
        let peer = MutationPeer(), owner = try owner(root, peer: peer, probe: probe)
        let input = try request(contents: source)
        return Fixture(root: root, source: source, peer: peer, owner: owner, input: input)
    }

    static func owner(_ root: URL, peer: MutationPeer, probe: TreeFrontierProbe? = nil) throws -> ProviderMutations {
        ProviderMutations(catalog: try Catalog(databaseURL: root.appendingPathComponent("catalog.sqlite")),
            staging: try MutationStaging(root: root.appendingPathComponent("Mutations")),
            remote: MutationRemote(stat: { try await peer.networkStat($0) }, mutate: { request, reconcile, progress in
                    do {
                        try await probe?.before(request, reconcile: reconcile)
                        let result = try await peer.mutate(request, reconcile, progress)
                        await probe?.after(request, failed: false)
                        return result
                    } catch {
                        await probe?.after(request, failed: true)
                        throw error
                    }
                },
                treeStat: { try await peer.treeStat($0, $1) },
                treeList: { try await peer.treeList($0, $1, page: $2) },
                treeRead: { path, destination, scope, progress in
                    let entry = try await peer.treeRead(path, destination, scope)
                    progress(entry.size); return entry
                }),
            checkActive: { try Task.checkCancellation() })
    }

    static func request(contents: URL?) throws -> MutationInput {
        try MutationInput(item: WriteTemplate(id: "tree-create-template", name: "Imported folder", directory: true),
            fields: [.filename, .parentItemIdentifier, .contents], contents: contents, allowDirectoryContents: true)
    }

    private static func publishedGraph() async throws {
        let fixture = try await fixture(wide: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let progress = Progress(totalUnitCount: 1)
        let root = try await fixture.owner.write(fixture.input, create: true, progress: progress)
        let children = try await fixture.owner.catalog.children(of: root.id)
        let nested = try await fixture.owner.catalog.child(named: "Nested", in: root.id)!
        let empty = try await fixture.owner.catalog.child(named: "Empty", in: nested.id)
        let liveRoot = try await fixture.owner.catalog.children().items
        let remote = await fixture.peer.treePaths()
        try mutationCheck(liveRoot.count == 1 && liveRoot[0].id == root.id && children.items.count == 102 && empty != nil,
                          "Tree publication exposed private scratch IDs or omitted nested/empty membership")
        try mutationCheck(remote.count == 105 && remote.allSatisfy { $0 == "Imported folder" || $0.hasPrefix("Imported folder/") },
                          "Published tree left executable scratch/arena paths or omitted original members")
        try mutationCheck(await fixture.peer.hash("Imported folder/TXT.rtf") == MutationPeer.hash(Data("the complete local package".utf8)) &&
            progress.completedUnitCount == progress.totalUnitCount, "Tree success did not attest original bytes or final progress")
        let staged = try FileManager.default.contentsOfDirectory(atPath: fixture.owner.staging.root.path)
        try mutationCheck(staged.isEmpty, "Verified tree publication did not retire clean local input/plans/arena")
        let count = await fixture.peer.counts().2
        let replay = try await fixture.owner.write(try request(contents: nil), create: true, progress: Progress(totalUnitCount: 1))
        let freshReplay = try await fixture.owner.write(fixture.input, create: true, progress: Progress(totalUnitCount: 1))
        let replayCalls = await fixture.peer.counts().2
        try mutationCheck(replay.id == root.id && freshReplay.id == root.id && replayCalls == count,
                          "Completed nil-contents callback replay reran a whole import")
        print("PASS NEW tree atomically publishes 100 small files, nested/empty directories and exact bytes; clean replay performs no RPC")
    }

    private static func readbackRestart() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.peer.setTreeReadCorrupt(true)
        let progress = Progress(totalUnitCount: 1)
        do {
            _ = try await fixture.owner.write(fixture.input, create: true, progress: progress)
            throw MutationTestFailure(message: "Unverified tree bytes were acknowledged")
        } catch is MutationTestFailure { throw MutationTestFailure(message: "Unverified tree bytes were acknowledged") }
        catch {}
        let rootID = try await fixture.owner.catalog.providerID(forCreateTemplate: fixture.input.id)
        let status = try await fixture.owner.catalog.treeImportStatus(rootID: rootID)!
        let live = try await fixture.owner.catalog.children().items
        try mutationCheck(status.phase == .frozen && live.isEmpty &&
            progress.completedUnitCount < progress.totalUnitCount, "Failed readback exposed a partial tree or reported completion")
        let snapshot = try LocalTreeSnapshot.load(status.tree, in: fixture.owner.staging)
        try mutationCheck(try snapshot.entries().count == 5, "Failed readback discarded durable input")
        try FileManager.default.removeItem(at: fixture.source)
        await fixture.peer.setTreeReadCorrupt(false)
        let restarted = try owner(fixture.root, peer: fixture.peer)
        let result = try await restarted.write(try request(contents: nil), create: true, progress: Progress(totalUnitCount: 1))
        let published = try await restarted.catalog.children().items
        try mutationCheck(result.id == rootID && published.count == 1,
                          "Restart did not resume the frozen tree after its system temporary source disappeared")
        print("PASS corrupt readback preserves a private tree and durable input; restart resumes without the original temporary source")
    }

    private static func lostPublication() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.peer.loseTreePublication(to: "Imported folder")
        do {
            _ = try await fixture.owner.write(fixture.input, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Lost final tree reply was invented as success")
        } catch is MutationTestFailure { throw MutationTestFailure(message: "Lost final tree reply was invented as success") }
        catch {}
        let before = await fixture.peer.counts().1
        try mutationCheck((try await fixture.owner.catalog.children()).items.isEmpty,
                          "Lost publish reply exposed an uncommitted Catalog graph")
        let replay = try await fixture.owner.write(try request(contents: nil), create: true, progress: Progress(totalUnitCount: 1))
        let after = await fixture.peer.counts().1
        // The staged root itself was renamed. Reconciliation proves its saved
        // identity without another create, place or post-publication removal.
        try mutationCheck(after == before && replay.entry.name == "Imported folder",
                          "Lost tree publication replay wrote a second payload instead of reconciling its frozen identity")
        print("PASS lost final tree reply reconciles the exact frozen payload and publishes one durable graph")
    }

    private static func parentFence() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.peer.setTreeReadCorrupt(true)
        do { _ = try await fixture.owner.write(fixture.input, create: true, progress: Progress(totalUnitCount: 1)) } catch {}
        await fixture.peer.setTreeReadCorrupt(false)
        await fixture.peer.replaceRoot()
        let count = await fixture.peer.counts().1
        do {
            _ = try await fixture.owner.write(try request(contents: nil), create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Tree replay adopted a replacement destination parent")
        } catch is MutationTestFailure { throw MutationTestFailure(message: "Tree replay adopted a replacement destination parent") }
        catch {}
        let finalCount = await fixture.peer.counts().1, live = try await fixture.owner.catalog.children().items
        try mutationCheck(finalCount == count && live.isEmpty,
                          "Replaced parent tree fence allowed publication or a new target")
        print("PASS private tree replay preserves its frozen parent fence instead of adopting a replacement at the same path")
    }

    private static func allocatedOwnerRestart() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.peer.useAllocatedReceipts(interruptWrite: true)
        do { _ = try await fixture.owner.write(fixture.input, create: true, progress: Progress(totalUnitCount: 1)) } catch {}
        let operations = try await fixture.owner.catalog.replayableOperations()
        var allocatedKey: UUID?
        for operation in operations {
            let key = operation.intent.idempotencyKey
            if let plan = try fixture.owner.staging.load(key), plan.steps.first?.request.receipt.staged?.phase == .allocated {
                allocatedKey = key
            }
        }
        guard let allocatedKey, let root = try await fixture.owner.catalog.treeImportOwner(operationKey: allocatedKey) else {
            throw MutationTestFailure(message: "Interrupted private upload lost allocated child ownership")
        }
        let calls = await fixture.peer.counts().2
        let restarted = try owner(fixture.root, peer: fixture.peer)
        _ = await restarted.maintain(limit: 128)
        try mutationCheck(await fixture.peer.counts().2 == calls, "Generic maintenance executed a private allocated child outside its root callback")
        let completed = try await restarted.write(try request(contents: nil), create: true, progress: Progress(totalUnitCount: 1))
        let hash = await fixture.peer.hash("Imported folder/Nested/Bytes.bin")
        try mutationCheck(completed.id == root.rootID && hash == MutationPeer.hash(Data([0, 1, 2, 255])),
                          "Restarted root callback failed to resume its allocated child bytes")
        print("PASS allocated private child survives restart; generic maintenance does not become a second upload driver")
    }

    private static func staleChildMaintenance() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.peer.useAllocatedReceipts(lostReplies: 1)
        do { _ = try await fixture.owner.write(fixture.input, create: true, progress: Progress(totalUnitCount: 1)) }
        catch {}
        do { _ = try await fixture.owner.write(try request(contents: nil), create: true, progress: Progress(totalUnitCount: 1)) }
        catch {}
        var candidate: MutationPlan?
        for key in fixture.owner.staging.planKeys(limit: 128) {
            if let plan = try fixture.owner.staging.load(key), plan.treeImport == nil, !plan.unresolvedAllocationPaths.isEmpty {
                candidate = plan; break
            }
        }
        guard let plan = candidate, let path = plan.unresolvedAllocationPaths.first else {
            throw MutationTestFailure(message: "Lost allocation evidence did not retain its historical journal")
        }
        // Even external disappearance cannot authorize publishing a tree whose
        // allocation authority was never acknowledged.
        await fixture.peer.remove(path)
        let writes = await fixture.peer.counts().1
        do {
            _ = try await fixture.owner.write(try request(contents: nil), create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Unknown allocation was cleared by observing its path absent")
        } catch is MutationTestFailure { throw MutationTestFailure(message: "Unknown allocation was cleared by observing its path absent") }
        catch {}
        let rootID = try await fixture.owner.catalog.providerID(forCreateTemplate: fixture.input.id)
        let status = try await fixture.owner.catalog.treeImportStatus(rootID: rootID)!
        let live = try await fixture.owner.catalog.children().items
        let finalWrites = await fixture.peer.counts().1
        try mutationCheck(status.phase == .frozen && live.isEmpty && writes == finalWrites &&
            (try fixture.owner.staging.load(plan.key))?.unresolvedAllocationPaths.contains(path) == true,
            "Unknown historical allocation allowed final publication or discarded its recovery evidence")
        print("PASS historical unknown allocation blocks publication even when its pathname is now absent")
    }

    private static func preflightRecovery() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.peer.setStatOffline(true)
        for _ in 0..<2 {
            do {
                _ = try await fixture.owner.write(fixture.input, create: true, progress: Progress(totalUnitCount: 1))
                throw MutationTestFailure(message: "Offline tree preflight was acknowledged")
            } catch is MutationTestFailure { throw MutationTestFailure(message: "Offline tree preflight was acknowledged") }
            catch {}
        }
        let keys = fixture.owner.staging.planKeys(limit: 128)
        let directories = try FileManager.default.contentsOfDirectory(atPath: fixture.owner.staging.root.path).filter { $0.hasSuffix(".tree") }
        let rootID = try await fixture.owner.catalog.providerID(forCreateTemplate: fixture.input.id)
        let status = try await fixture.owner.catalog.treeImportStatus(rootID: rootID)
        try mutationCheck(keys.count == 1 && directories.count == 1 && status == nil,
                          "Repeated preflight failure accumulated full-tree snapshots or created executable remote work")
        let retained = try fixture.owner.staging.load(keys[0])!.treeImport!.tree
        try FileManager.default.removeItem(at: fixture.source)
        await fixture.peer.setStatOffline(false)
        let restarted = try owner(fixture.root, peer: fixture.peer)
        let completed = try await restarted.write(try request(contents: nil), create: true, progress: Progress(totalUnitCount: 1))
        let published = try await restarted.catalog.treeImportStatus(rootID: rootID)
        try mutationCheck(completed.id == rootID && published?.tree.id == retained.id,
                          "Nil-contents retry abandoned the durably retained preflight snapshot")
        for coreOwned in [false, true] {
            for damage in 0..<3 { try await damagedRetainedInput(coreOwned: coreOwned, damage: damage) }
        }
        print("PASS offline preflight retries reuse one snapshot; restart with missing system input resumes the deterministic local recovery reference")
    }

    private static func damagedRetainedInput(coreOwned: Bool, damage: Int) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        if coreOwned { await f.peer.setTreeReadCorrupt(true) }
        else { await f.peer.setStatOffline(true) }
        do { _ = try await f.owner.write(f.input, create: true, progress: Progress(totalUnitCount: 1)) } catch {}
        let rootID = try await f.owner.catalog.providerID(forCreateTemplate: f.input.id)
        let status = try await f.owner.catalog.treeImportStatus(rootID: rootID)
        let key = status?.key ?? f.owner.staging.planKeys(limit: 128).first!
        let retained = try f.owner.staging.load(key)!.treeImport!.tree
        let oldSnapshot = try LocalTreeSnapshot.load(retained, in: f.owner.staging)
        let payload = try oldSnapshot.entries().compactMap(\.payload).first!
        let oldDirectory = f.owner.staging.root.appendingPathComponent(retained.id.uuidString.lowercased() + ".tree")
        switch damage {
        case 0: try Data("damaged retained index".utf8).write(to: oldDirectory.appendingPathComponent("manifest.sqlite"))
        case 1: try FileManager.default.removeItem(at: oldSnapshot.payloadURL(payload))
        default: try Data(repeating: 7, count: Int(payload.size)).write(to: oldSnapshot.payloadURL(payload))
        }
        let calls = await f.peer.counts().2
        do {
            _ = try await f.owner.write(f.input, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Corrupt retained input was acknowledged")
        } catch is MutationTestFailure { throw MutationTestFailure(message: "Corrupt retained input was acknowledged") }
        catch {}
        let directories = try FileManager.default.contentsOfDirectory(at: f.owner.staging.root,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "tree" }
        let fresh = directories.first { $0.lastPathComponent != oldDirectory.lastPathComponent }
        let freshEntries = try fresh.map { try LocalTreeIndex(directory: $0, create: false).entries(after: nil, limit: 128) }
        let finalCalls = await f.peer.counts().2
        let originalReference = try f.owner.staging.load(key)?.treeImport?.tree
        try mutationCheck(directories.count == 2 && freshEntries?.count == 5 && originalReference == retained && finalCalls == calls,
                          "Damaged retained input discarded the fresh complete copy or replaced recovery authority")
    }
}
