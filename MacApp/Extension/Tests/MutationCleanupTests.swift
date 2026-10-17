import FileProvider
import Foundation
import MyDriveCore
import Darwin

extension MutationTests {
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
