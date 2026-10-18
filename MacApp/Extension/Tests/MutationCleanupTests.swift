import FileProvider
import Foundation
import MyDriveCore
import Darwin

extension MutationTests {
    static func postCommitCancellation() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x71, count: 131_073) + Data(" — café\n".utf8)
        let hash = MutationPeer.hash(bytes)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let peer = MutationPeer()
        let catalog = try Catalog(databaseURL: root.appendingPathComponent("catalog.sqlite"))
        let staging = try MutationStaging(root: root.appendingPathComponent("Mutations"))
        let before = await peer.seed(path: "Edit.txt", bytes: Data("before".utf8))
        let scan = try await catalog.beginScan()
        try await catalog.stage([before.observation], in: scan)
        try await catalog.completeScan(scan)
        let original = try await catalog.children().items[0]
        let input = try MutationInput(item: WriteTemplate(id: original.id, name: "Edit.txt"),
            fields: [.contents], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(before.observation.contentVersion.utf8),
                                                  metadataVersion: Data(before.observation.metadataVersion.utf8)))
        let key = input.operationID(create: false,
            payload: StagedPayload(id: UUID(), size: Int64(bytes.count), sha256: hash))
        let cancellation = CancellationLatch()
        let remote = MutationRemote(stat: { await peer.stat($0) }, mutate: { request, reconcile, progress in
            let result = try await peer.mutate(request, reconcile, progress)
            if request.kind == .cleanup {
                // Cancel only after a real Catalog transaction has stored the
                // accepted item and receipt, during its best-effort cleanup.
                let receipt = try await catalog.mutationResult(key: key)
                try mutationCheck(receipt?.items.first?.id == original.id,
                                  "Cleanup ran before durable publication")
                await cancellation.set(true)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return result
        })
        let adapter = ProviderMutations(catalog: catalog, staging: staging, remote: remote,
            checkActive: { try Task.checkCancellation(); try await cancellation.check() })
        let progress = Progress(totalUnitCount: 1)
        let upload = Task {
            let accepted = try await adapter.write(input, create: false, progress: progress)
            try mutationCheck(Task.isCancelled, "The upload task was not cancelled during cleanup")
            return accepted
        }
        let accepted: CatalogItem
        do { accepted = try await upload.value }
        catch is CancellationError {
            throw MutationTestFailure(message: "A durably committed upload returned cancellation during cleanup")
        }
        guard let remoteEntry = await peer.stat("Edit.txt"),
              let receipt = try await catalog.mutationResult(key: key),
              let operation = try await catalog.operation(key: key), let payload = operation.intent.payload else {
            throw MutationTestFailure(message: "Committed upload lost its remote item or durable receipt")
        }
        let current = try await catalog.item(id: original.id)
        let counts = await peer.counts()
        let didCancel = await cancellation.cancelled
        let cleanupCalls = await peer.cleanupCalls
        let remoteHash = await peer.hash("Edit.txt")
        try mutationCheck(!Task.isCancelled && didCancel && cleanupCalls == 1,
                          "The regression did not cancel during postcommit cleanup")
        try mutationCheck(accepted.id == original.id && accepted.entry == remoteEntry.observation &&
            receipt.items == [accepted] && current == accepted && operation.state == .completed,
            "Late cancellation changed the exact accepted item or completed result")
        try mutationCheck(remoteHash == hash && (try Data(contentsOf: source)) == bytes &&
            progress.completedUnitCount == progress.totalUnitCount && staging.planKeys(limit: 8).isEmpty,
            "Committed upload lost bytes, completion progress or its confirmed cleanup")
        try mutationCheck(!FileManager.default.fileExists(atPath: staging.payloadURL(payload.id).path),
                          "Completed upload retained its disposable payload")

        await cancellation.set(false)
        let replayed = try await Task {
            try await adapter.write(input, create: false, progress: Progress(totalUnitCount: 1))
        }.value
        let replayCounts = await peer.counts()
        let replayHash = await peer.hash("Edit.txt")
        try mutationCheck(replayed == accepted && replayCounts.0 == counts.0 && replayCounts.1 == counts.1 &&
            replayCounts.2 == counts.2 && replayHash == hash && staging.planKeys(limit: 8).isEmpty,
            "Completed callback replay changed the accepted item or repeated remote work")
        print("PASS cancellation during postcommit cleanup returns the exact durable item, completes progress and replays without reupload")
        return 1
    }

    static func postCommitCleanup() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let cleanupPeer = MutationPeer()
        let cleanup = try fixture(root.appendingPathComponent("cleanup"), cleanupPeer)
        let before = await cleanupPeer.seed(path: "Edit.txt", bytes: Data("before".utf8))
        let beforeScan = try await cleanup.catalog.beginScan()
        try await cleanup.catalog.stage([before.observation], in: beforeScan)
        try await cleanup.catalog.completeScan(beforeScan)
        let beforeItem = try await cleanup.catalog.children().items[0]
        let cleanupInput = try MutationInput(item: WriteTemplate(id: beforeItem.id, name: "Edit.txt"),
            fields: [.contents], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(before.observation.contentVersion.utf8),
                                                  metadataVersion: Data(before.observation.metadataVersion.utf8)))
        await cleanupPeer.failNextCleanup()
        _ = try await cleanup.write(cleanupInput, create: false, progress: Progress(totalUnitCount: 1))
        try mutationCheck(cleanup.staging.planKeys(limit: 10).count == 1, "Failed cleanup discarded its durable receipt")
        let publishCounts = await cleanupPeer.counts()
        _ = try await cleanup.write(cleanupInput, create: false, progress: Progress(totalUnitCount: 1))
        let afterCleanupCounts = await cleanupPeer.counts()
        try mutationCheck(cleanup.staging.planKeys(limit: 10).isEmpty && publishCounts.1 == afterCleanupCounts.1,
                          "Completed replay reuploaded data or failed to retire confirmed cleanup")
        print("PASS post-commit cleanup failure retains its receipt and completed replay cleans without reuploading")
        return 1
    }

    static func unsafeArchive() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let unsafePeer = MutationPeer()
        let unsafe = try fixture(root.appendingPathComponent("unsafe"), unsafePeer)
        let retainedBase = await unsafePeer.seed(path: "Retain.txt", bytes: Data("retained original".utf8))
        let retainedScan = try await unsafe.catalog.beginScan()
        try await unsafe.catalog.stage([retainedBase.observation], in: retainedScan)
        try await unsafe.catalog.completeScan(retainedScan)
        let retainedItem = try await unsafe.catalog.children().items[0]
        await unsafePeer.markArchiveUnsafe()
        let retainedInput = try MutationInput(item: WriteTemplate(id: retainedItem.id, name: "Retain.txt"),
            fields: [.contents], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(retainedBase.observation.contentVersion.utf8),
                                                  metadataVersion: Data(retainedBase.observation.metadataVersion.utf8)))
        _ = try await unsafe.write(retainedInput, create: false, progress: Progress(totalUnitCount: 1))
        let unsafeStatus = await unsafe.maintain()
        let unsafeCleanupCalls = await unsafePeer.cleanupCalls
        try mutationCheck(unsafeStatus.retained == 1 && unsafe.staging.planKeys(limit: 10).count == 1 && unsafeCleanupCalls == 0,
                          "Unverified recovery archive was automatically destroyed or its evidence discarded")
        print("PASS unsafe recovery archives remain retained and are reported without automatic cleanup")
        return 1
    }

}
