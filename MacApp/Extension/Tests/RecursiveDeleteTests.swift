import FileProvider
import Foundation
import MyDriveCore

private struct RecursiveTestFailure: Error { let message: String }

private actor TreePeer {
    static let share = SMBEntry(name: "", bytes: 0, directory: true, index_number: 1,
        created_filetime: 1, modified_filetime: 1, changed_filetime: 1, attributes: 0x10)
    private var entries: [String: SMBEntry] = [:]
    private var next: UInt64 = 10
    private(set) var lists: [String: Int] = [:]
    private(set) var deletes: [String] = []
    private(set) var cleanupCalls = 0
    private var failList: String?
    private var failCleanup = false
    private var lateChild = false
    private var moveSelectionAfterCleanup = false
    private var editBeforeDelete: String?

    func seed(_ path: String, directory: Bool = false, reparse: Bool = false) {
        next += 1
        entries[path] = SMBEntry(name: String(path.split(separator: "/").last!), bytes: directory ? 0 : 7,
            directory: directory, index_number: next, created_filetime: next,
            modified_filetime: next, changed_filetime: next, attributes: (directory ? 0x10 : 0x20) | (reparse ? 0x400 : 0))
        bumpParent(path)
    }
    func removeExternally(_ path: String) { entries.removeValue(forKey: path); bumpParent(path) }
    func failListingOnce(_ path: String) { failList = path }
    func failCleanupOnce() { failCleanup = true }
    func addLateChildAtRootDelete() { lateChild = true }
    func moveRootAfterFirstCleanup() { moveSelectionAfterCleanup = true }
    func editBeforeGuardedDelete(_ path: String) { editBeforeDelete = path }
    func stat(_ path: String) -> SMBEntry? { path.isEmpty ? Self.share : entries[path] }
    func children(_ path: String) -> [SMBEntry] {
        entries.keys.filter { parent($0).utf8.elementsEqual(path.utf8) }.sorted().compactMap { entries[$0] }
    }
    private func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    private func bumpParent(_ path: String) {
        let path = parent(path)
        guard let old = entries[path] else { return }
        entries[path] = SMBEntry(name: old.name, bytes: old.bytes, directory: old.directory,
            index_number: old.index_number, created_filetime: old.created_filetime,
            modified_filetime: old.modified_filetime + 1, changed_filetime: old.changed_filetime + 1, attributes: old.attributes)
    }
    private func check(_ path: String, scope: SMBDeleteScope, rootMayBeAbsent: Bool = false) throws {
        guard scope.contains(path), let parent = stat(parent(scope.root_path)),
              parent.objectIdentity.map(SMBMutationRequest.ParentIdentity.init) == scope.parent else { throw SMBClientError.scopeChanged }
        if rootMayBeAbsent && path.utf8.elementsEqual(scope.root_path.utf8) && stat(path) == nil { return }
        guard stat(scope.root_path)?.objectIdentity.map(SMBMutationRequest.ParentIdentity.init) == scope.root else {
            throw SMBClientError.scopeChanged
        }
    }
    func scopedStat(_ path: String, _ scope: SMBDeleteScope) throws -> SMBEntry? {
        try check(path, scope: scope, rootMayBeAbsent: true); return stat(path)
    }
    func list(_ path: String, _ scope: SMBDeleteScope,
              page: @Sendable ([RemoteEntry]) async throws -> Void) async throws -> SMBEntry {
        try check(path, scope: scope)
        guard let directory = stat(path), directory.directory else { throw SMBClientError.itemMissing }
        lists[path, default: 0] += 1
        let values = children(path)
        for offset in stride(from: 0, to: values.count, by: 2) {
            try await page(values[offset..<min(offset + 2, values.count)].map(\.observation))
            if failList == path { failList = nil; throw SMBClientError.serverUnreachable }
        }
        return directory
    }
    func mutate(_ request: SMBMutationRequest, _ reconcile: Bool) throws -> SMBMutationResult {
        guard let scope = request.delete_scope else { throw SMBClientError.invalidResponse }
        var receipt = request.receipt
        func result(_ outcome: SMBMutationResult.Outcome, _ code: String) -> SMBMutationResult {
            SMBMutationResult(operation_id: request.operation_id, outcome: outcome, code: code,
                entry: nil, sha256: nil, cleanup_pending: receipt.archived != nil, receipt: receipt)
        }
        do { try check(request.path, scope: scope, rootMayBeAbsent: request.path == scope.root_path) }
        catch { return result(.conflict, "scope_changed") }
        guard stat(parent(request.path))?.objectIdentity.map(SMBMutationRequest.ParentIdentity.init) == request.parent else {
            return result(.conflict, "parent_changed")
        }
        if request.kind == .cleanup {
            cleanupCalls += 1
            if failCleanup { failCleanup = false; throw SMBClientError.serverUnreachable }
            if let current = stat(request.path), current != request.expected { return result(.conflict, "changed") }
            entries.removeValue(forKey: request.path); bumpParent(request.path)
            if moveSelectionAfterCleanup {
                moveSelectionAfterCleanup = false
                let moving = entries.keys.filter { $0 == scope.root_path || $0.hasPrefix(scope.root_path + "/") }
                for old in moving.sorted() {
                    let new = "Outside" + old.dropFirst(scope.root_path.count)
                    if let entry = entries.removeValue(forKey: old) { entries[new] = entry }
                }
                seed(scope.root_path, directory: true); seed(scope.root_path + "/replacement.txt")
            }
            return result(.committed, "committed")
        }
        guard request.kind == .delete else { throw SMBClientError.invalidResponse }
        if !reconcile, editBeforeDelete == request.path {
            editBeforeDelete = nil
            seed(request.path)
            return result(.conflict, "changed")
        }
        guard let current = stat(request.path) else { return result(.committed, "committed") }
        guard current == request.expected else { return result(.conflict, "changed") }
        if reconcile { return result(.notApplied, "not_applied") }
        if current.directory {
            if lateChild && request.path == scope.root_path {
                lateChild = false; seed(scope.root_path + "/new.txt")
            }
            if !children(request.path).isEmpty { return result(.notApplied, "directory_not_empty") }
        }
        deletes.append(request.path)
        entries.removeValue(forKey: request.path); bumpParent(request.path)
        if !current.directory {
            let path = request.sidecar("deleted")
            let archived = SMBEntry(name: String(path.split(separator: "/").last!), bytes: current.bytes, directory: false,
                index_number: current.index_number, created_filetime: current.created_filetime,
                modified_filetime: current.modified_filetime, changed_filetime: current.changed_filetime + 1, attributes: current.attributes)
            entries[path] = archived
            receipt.archived = .init(path: path, entry: archived, cleanup_safe: true)
        }
        return result(.committed, "committed")
    }
}

private struct TreeFixture: Sendable {
    let catalog: Catalog
    let versions: DomainVersionSnapshot
    let mutations: ProviderMutations
    let peer: TreePeer
    let rootID: String

    static func make(_ path: URL, peer: TreePeer,
                     check: @escaping @Sendable () async throws -> Void = { try Task.checkCancellation() }) async throws -> Self {
        let catalog = try Catalog(databaseURL: path.appendingPathComponent("catalog.sqlite"),
                                  initialDomainVersionArchive: DomainVersionSnapshot.initialArchive())
        if try await !catalog.hasCompletedScan(of: Catalog.rootID) {
            let scan = try await catalog.beginScan()
            try await catalog.stage(await peer.children("").map(\.observation), in: scan)
            try await catalog.completeScan(scan)
        }
        let item = try await catalog.child(named: "Tree", in: Catalog.rootID)!
        let remote = MutationRemote(stat: { await peer.stat($0) }, mutate: { request, reconcile, _ in
            try await peer.mutate(request, reconcile)
        }, scopedStat: { try await peer.scopedStat($0, $1) }, scopedList: { try await peer.list($0, $1, page: $2) })
        return Self(catalog: catalog, versions: try DomainVersionSnapshot(catalog.initialDomainVersionState!),
            mutations: ProviderMutations(catalog: catalog, staging: try MutationStaging(root: path.appendingPathComponent("Mutations")),
                remote: remote, checkActive: check), peer: peer, rootID: item.id)
    }
    func context() async throws -> DeletionRequestContext {
        try await versions.resolve(versions.durableState!.archive, recursive: true) { try await catalog.domainVersionState(epoch: $0) }
    }
    func run(_ context: DeletionRequestContext, progress: Progress = Progress(totalUnitCount: 1),
             published: @escaping @Sendable () async -> Void = {}) async throws {
        let item = try await catalog.item(id: rootID)!
        try await ProviderRecursiveDelete(mutations: mutations, versions: versions, published: published)
            .delete(id: rootID, contentVersion: Data(item.entry.contentVersion.utf8),
                    metadataVersion: Data(item.entry.metadataVersion.utf8), context: context, progress: progress)
    }
}

private actor TreeCancellation {
    var stopped = false
    func check() throws { if stopped { throw CancellationError() } }
    func stop() { stopped = true }
}

/// Each scenario owns its fixture and loop so optimized tests do not build one
/// giant async state machine. These peers never open SMB, Keychain or Finder.
enum RecursiveDeleteTests {
    private static func checked(_ value: Bool, _ message: String) throws { if !value { throw RecursiveTestFailure(message: message) } }
    private static func location() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    static func run() async throws -> Int {
        try await postorder()
        try await incompleteInventory()
        try await cleanupRetry()
        try await cancellation()
        try await lateChildren()
        try await movedSelection()
        try await unsupportedEntries()
        try await alreadyAbsentChild()
        try await freshRootConflict()
        try await guardedDeleteConflict()
        try await nestedPackageRefusal()
        try await historicalPackageRefusal()
        try await ordinaryDeleteDedupe(completed: false)
        try await ordinaryDeleteDedupe(completed: true)
        try scopeBytes()
        return 15
    }

    private static func historicalPackageRefusal() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/ordinary.txt")
        await peer.seed("Tree/Nested", directory: true); await peer.seed("Tree/Nested/Document.rtfd", directory: true)
        await peer.seed("Tree/Nested/Document.rtfd/TXT.rtf")
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        let root = try await fixture.catalog.item(id: fixture.rootID)!
        let intent = JournalIntent(idempotencyKey: MutationInput.recursiveDeletionID(id: root.id,
            content: Data(root.entry.contentVersion.utf8), metadata: Data(root.entry.metadataVersion.utf8), context: context.issuedContextID),
            itemID: root.id, expectedVersion: root.entry.contentVersion, action: .deleteTree,
            expectedMetadataVersion: root.entry.metadataVersion, sourcePath: "Tree", baseEntry: root.entry,
            deletionContextID: context.issuedContextID?.uuidString.lowercased())
        let status = try await fixture.catalog.prepareRecursiveDelete(intent: intent,
            rootParentIdentity: TreePeer.share.objectIdentity!, requestContext: context.archive)
        // Simulate a frozen inventory written by the previous implementation,
        // before the native package preservation policy existed.
        while true {
            let work = try await fixture.catalog.nextRecursiveDeleteWork(key: status.key)
            guard let first = work.first, case .capture = first else { break }
            for case .capture(let item, let remotePath, _) in work {
                let scan = try await fixture.catalog.beginScan(of: item.id)
                try await fixture.catalog.stage(await peer.children(remotePath).map(\.observation), in: scan)
                let terminal = await peer.stat(remotePath)!.observation
                _ = try await fixture.catalog.captureDeleteDirectory(key: status.key, scan: scan, directory: terminal)
            }
        }
        let nested = try await fixture.catalog.child(named: "Nested", in: fixture.rootID)!
        let refresh = try await fixture.catalog.beginScan(of: nested.id)
        try await fixture.catalog.completeScan(refresh)
        try checked(try await fixture.catalog.children(of: nested.id).items.isEmpty,
                    "Historical fixture did not retire the current Catalog package graph")
        do { try await fixture.run(context); throw RecursiveTestFailure(message: "An old frozen manifest bypassed package preflight") }
        catch let error as NSFileProviderError where error.code == .deletionRejected {}
        let noDeletes = await peer.deletes.isEmpty, kept = await peer.stat("Tree/Nested/Document.rtfd/TXT.rtf")
        try checked(noDeletes && kept != nil, "Historical frozen inventory began removing files before package qualification")
        print("PASS historical frozen inventory is fully qualified before any removal even when current Catalog has retired its package nodes")
    }

    private static func nestedPackageRefusal() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/ordinary.txt")
        await peer.seed("Tree/Nested", directory: true); await peer.seed("Tree/Nested/Document.rtfd", directory: true)
        await peer.seed("Tree/Nested/Document.rtfd/TXT.rtf")
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        do { try await fixture.run(context); throw RecursiveTestFailure(message: "A recursive containing folder deleted package bytes") }
        catch let error as NSFileProviderError where error.code == .deletionRejected {}
        let noDeletes = await peer.deletes.isEmpty, keptPackage = await peer.stat("Tree/Nested/Document.rtfd/TXT.rtf")
        try checked(noDeletes && keptPackage != nil, "Nested package discovery allowed a destructive RPC before refusal")
        print("PASS recursive containing-folder discovery refuses a nested package before any destructive RPC")
    }

    private static func guardedDeleteConflict() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/a.txt")
        await peer.editBeforeGuardedDelete("Tree/a.txt")
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        do { try await fixture.run(context); throw RecursiveTestFailure(message: "A file changed after preflight was deleted") }
        catch let error as NSFileProviderError where error.code == .deletionRejected {}
        let noDeletes = await peer.deletes.isEmpty, retainedFile = await peer.stat("Tree/a.txt")
        try checked(noDeletes && retainedFile != nil,
                    "A guarded post-preflight conflict removed concurrent bytes")
        let retained = try await fixture.catalog.item(id: fixture.rootID)
        try checked(retained?.isDeleted == false && fixture.mutations.staging.planKeys(limit: 8).count == 1,
                    "Restoring refusal lost the selected root or its child intent")
        print("PASS guarded delete conflicts after preflight restore the selected folder and preserve the concurrent remote file")
    }

    private static func postorder() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/Nested", directory: true)
        await peer.seed("Tree/Nested/leaf.txt"); await peer.seed("Tree/top.txt"); await peer.seed("Keep.txt")
        let fixture = try await TreeFixture.make(path, peer: peer)
        let context = try await fixture.context(), progress = Progress(totalUnitCount: 1)
        try await fixture.run(context, progress: progress)
        let deleted = await peer.deletes
        try checked(deleted.count == 4 && deleted.last == "Tree" &&
            deleted.firstIndex(of: "Tree/Nested/leaf.txt")! < deleted.firstIndex(of: "Tree/Nested")!, "Delete was not postorder")
        let kept = await peer.stat("Keep.txt"), rootGone = await peer.stat("Tree") == nil
        try checked(kept != nil && rootGone, "Deletion crossed its selected root")
        try checked(progress.totalUnitCount == 4 && progress.completedUnitCount == 4 && fixture.versions.durableState!.epoch == 4,
                    "Native completion or domain version advanced before durable per-node removal")
        try await fixture.run(context)
        try checked(await peer.deletes.count == 4, "Completed native delete replay repeated a remote mutation")
        print("PASS recursive delete captures an unopened tree, freshens directory metadata and commits permanent removals in postorder with native versions")
    }

    private static func incompleteInventory() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/Nested", directory: true)
        await peer.seed("Tree/Nested/a.txt"); await peer.seed("Tree/Nested/b.txt")
        await peer.failListingOnce("Tree/Nested")
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        let progress = Progress(totalUnitCount: 1)
        do { try await fixture.run(context, progress: progress); throw RecursiveTestFailure(message: "Partial inventory was accepted") }
        catch SMBClientError.serverUnreachable {}
        try checked(await peer.deletes.isEmpty && progress.totalUnitCount < 0, "Preparation deleted a partially enumerated tree or invented completion")
        let restored = try await TreeFixture.make(path, peer: peer)
        try await restored.run(context)
        try checked(await peer.lists["Tree"] == 2, "Preparation repeated the completed root capture instead of only its frontier plus final emptiness check")
        print("PASS failed inventory makes no remote mutations and restart resumes durable completed-directory checkpoints")
    }

    private static func cleanupRetry() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/a.txt"); await peer.failCleanupOnce()
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        do { try await fixture.run(context); throw RecursiveTestFailure(message: "Pending permanent cleanup was acknowledged") }
        catch let error as NSError { try checked(error.domain == NSCocoaErrorDomain, "Cleanup error lost its pending status") }
        try checked(await peer.stat("Tree") != nil && fixture.mutations.staging.planKeys(limit: 8).count == 1,
                    "Cleanup failure retired the root or lost the exact child receipt")
        let restored = try await TreeFixture.make(path, peer: peer)
        try await restored.run(context)
        let deleted = await peer.deletes, rootGone = await peer.stat("Tree") == nil
        try checked(deleted.filter { $0 == "Tree/a.txt" }.count == 1 && rootGone,
                    "Cleanup replay repeated a verified namespace delete or failed to finish")
        print("PASS recursive completion waits for permanent byte cleanup and owner restart reuses the same receipt")
    }

    private static func cancellation() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/a.txt"); await peer.seed("Tree/b.txt")
        let stop = TreeCancellation()
        let fixture = try await TreeFixture.make(path, peer: peer, check: { try await stop.check() })
        let context = try await fixture.context(), progress = Progress(totalUnitCount: 1)
        do {
            try await fixture.run(context, progress: progress) {
                if fixture.versions.durableState!.epoch > 0 { await stop.stop() }
            }
            throw RecursiveTestFailure(message: "Cancelled tree deletion finished")
        } catch is CancellationError {}
        try checked(progress.completedUnitCount == 1 && fixture.versions.durableState!.epoch == 1,
                    "Cancellation lost committed progress or advanced unconfirmed native state")
        let restored = try await TreeFixture.make(path, peer: peer)
        try await restored.run(context)
        let deleted = await peer.deletes
        try checked(deleted.count == 3 && Set(deleted).count == 3, "Restart repeated confirmed child removal")
        print("PASS cancellation stops the callback promptly while committed progress and native domain context survive restart")
    }

    private static func lateChildren() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/old.txt"); await peer.addLateChildAtRootDelete()
        let fixture = try await TreeFixture.make(path, peer: peer), original = try await fixture.context()
        do { try await fixture.run(original); throw RecursiveTestFailure(message: "Concurrent new child was deleted") }
        catch let error as NSFileProviderError where error.code == .directoryNotEmpty {}
        let nilContext = DeletionRequestContext(recursive: true, archive: nil, issuedContextID: nil)
        do { try await fixture.run(nilContext); throw RecursiveTestFailure(message: "Nil request expanded the previous frozen inventory") }
        catch let error as NSFileProviderError where error.code == .directoryNotEmpty || error.code == .deletionRejected {}
        try checked(await peer.stat("Tree/new.txt") != nil, "Frozen replay consumed an unselected new child")
        let rootScan = try await fixture.catalog.beginScan()
        try await fixture.catalog.stage(await peer.children("").map(\.observation), in: rootScan)
        try await fixture.catalog.completeScan(rootScan)
        let next = try await fixture.context()
        try checked(next.issuedContextID != original.issuedContextID, "Partial progress did not issue a new native state")
        try await fixture.run(next)
        try checked(await peer.stat("Tree") == nil, "A real later explicit request could not authorize a new inventory")
        try await fixture.run(original)
        print("PASS old and nil requests never expand a frozen inventory; a later issued native context can authorize a new explicit deletion")
    }

    private static func movedSelection() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/a.txt"); await peer.seed("Tree/b.txt")
        await peer.moveRootAfterFirstCleanup()
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        do { try await fixture.run(context); throw RecursiveTestFailure(message: "A moved/replaced selection was followed") }
        catch SMBClientError.scopeChanged {}
        let replacement = await peer.stat("Tree/replacement.txt"), moved = await peer.stat("Outside")
        try checked(replacement != nil && moved != nil,
                    "Deletion crossed a moved-root fence or removed replacement data")
        try checked(await peer.deletes.count == 1, "More children were removed after the selection moved")
        print("PASS held selection fences stop deletion after a root moves outside scope and preserve replacement namespace data")
    }

    private static func unsupportedEntries() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/ordinary.txt")
        await peer.seed("Tree/link", directory: true, reparse: true)
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        do { try await fixture.run(context); throw RecursiveTestFailure(message: "Reparse inventory was accepted") }
        catch let error as NSFileProviderError where error.code == .deletionRejected {}
        try checked(await peer.deletes.isEmpty, "Unsupported inventory started deleting before full qualification")
        print("PASS reparse entries are typed as unsupported and fail inventory before any remote deletion")
    }

    private static func alreadyAbsentChild() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/gone.txt")
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        let once = TreeCancellation()
        try await fixture.run(context) {
            if await !once.stopped {
                await once.stop()
                await peer.removeExternally("Tree/gone.txt")
                let scan = try! await fixture.catalog.beginScan(of: fixture.rootID)
                try! await fixture.catalog.completeScan(scan)
            }
        }
        try checked(await peer.deletes == ["Tree"], "An already absent tombstoned child needed a fabricated delete request")
        print("PASS scoped absence completes a frozen child even after Catalog retirement without resurrecting it or fabricating SMB metadata")
    }
    private static func freshRootConflict() async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/old.txt")
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        await peer.seed("Tree/new.txt")
        do { try await fixture.run(context); throw RecursiveTestFailure(message: "A fresh stale-base delete adopted new root metadata") }
        catch let error as NSFileProviderError where error.code == .deletionRejected {}
        let deleted = await peer.deletes, listed = await peer.lists
        try checked(deleted.isEmpty && listed.isEmpty, "A stale initial root callback reached inventory or mutation")
        try checked(try await fixture.catalog.recursiveDeleteStatus(rootID: fixture.rootID, contextID: context.issuedContextID) == nil,
                    "A rejected initial callback left a dangerous durable inventory for retry")
        print("PASS a fresh stale-base root deletion is rejected before inventory creation and preserves newly arrived remote children")
    }

    private static func ordinaryDeleteDedupe(completed: Bool) async throws {
        let path = try location(); defer { try? FileManager.default.removeItem(at: path) }
        let peer = TreePeer(); await peer.seed("Tree", directory: true); await peer.seed("Tree/a.txt")
        let fixture = try await TreeFixture.make(path, peer: peer), context = try await fixture.context()
        let root = try await fixture.catalog.item(id: fixture.rootID)!
        let rootKey = MutationInput.recursiveDeletionID(id: root.id, content: Data(root.entry.contentVersion.utf8),
            metadata: Data(root.entry.metadataVersion.utf8), context: context.issuedContextID)
        let intent = JournalIntent(idempotencyKey: rootKey, itemID: root.id, expectedVersion: root.entry.contentVersion,
            action: .deleteTree, expectedMetadataVersion: root.entry.metadataVersion, sourcePath: "Tree", baseEntry: root.entry,
            deletionContextID: context.issuedContextID?.uuidString.lowercased())
        var status = try await fixture.catalog.prepareRecursiveDelete(intent: intent,
            rootParentIdentity: TreePeer.share.objectIdentity!, requestContext: context.archive)
        let scan = try await fixture.catalog.beginScan(of: root.id)
        try await fixture.catalog.stage(await peer.children("Tree").map(\.observation), in: scan)
        status = try await fixture.catalog.captureDeleteDirectory(key: status.key, scan: scan, directory: await peer.stat("Tree")!.observation)
        guard case .remove(let child, let childPath, let parent, _, _) = try await fixture.catalog.nextRecursiveDeleteWork(key: status.key, limit: 1).first! else {
            throw RecursiveTestFailure(message: "Frozen child fixture missing")
        }
        let normalKey = UUID(), expected = await peer.stat(childPath)!
        let ordinary = JournalIntent(idempotencyKey: normalKey, itemID: child.id, expectedVersion: child.entry.contentVersion,
            action: .delete, expectedMetadataVersion: child.entry.metadataVersion, sourcePath: childPath, baseEntry: child.entry)
        _ = try await fixture.catalog.enqueue(ordinary)
        var unscoped = SMBMutationRequest(operationID: normalKey, kind: .delete, path: childPath, parent: .init(parent), expected: expected)
        var result: SMBMutationResult?
        if completed {
            let scoped = SMBMutationRequest(operationID: normalKey, kind: .delete, path: childPath,
                parent: .init(parent), expected: expected, deleteScope: SMBDeleteScope(status.scope))
            result = try await peer.mutate(scoped, false)
            unscoped.receipt = result!.receipt
            _ = try await fixture.catalog.transitionOperation(key: normalKey, from: .queued, to: .executing)
            _ = try await fixture.catalog.commitMutation(key: normalKey, upserts: [], tombstones: [child.id])
        }
        try fixture.mutations.staging.save(MutationPlan(key: normalKey, itemID: child.id, parentID: root.id,
            filename: child.entry.name, steps: [.init(request: unscoped, result: result)], preservedOriginal: nil))
        try await fixture.run(context)
        try checked(await peer.stat("Tree") == nil, "Canonical ordinary delete could not finish under its added selection fences")
        let normal = try await fixture.catalog.operation(key: normalKey)
        try checked(normal?.state == .completed && fixture.mutations.staging.planKeys(limit: 8).isEmpty,
                    "Dedupe changed the journal authority or left verified cleanup pending")
        print("PASS \(completed ? "completed ordinary cleanup" : "queued ordinary delete") deduped into recursive work inherits persisted narrowing fences before replay")
    }

    private static func scopeBytes() throws {
        let composed = "Caf\u{e9}", decomposed = composed.decomposedStringWithCanonicalMapping
        func scope(_ path: String) throws -> SMBDeleteScope {
            let data = try JSONSerialization.data(withJSONObject: ["root_path": path,
                "root": ["index_number": 1, "created_filetime": 2], "parent": ["index_number": 3, "created_filetime": 4]])
            return try JSONDecoder().decode(SMBDeleteScope.self, from: data)
        }
        let first = try scope(composed), second = try scope(decomposed)
        try checked(first != second && first.contains(composed + "/child") && !first.contains(decomposed + "/child"),
                    "Selection fences canonically equated different remote path bytes")
        print("PASS scoped replay qualification and membership distinguish canonical-equivalent Unicode byte paths")
    }

}
