import FileProvider
import Foundation
import MyDriveCore

enum MutationRecoveryTests {
    static func run() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("a dirty offline save that must survive a remote delete".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let peer = MutationPeer()
        let adapter = try MutationTests.fixture(root.appendingPathComponent("before-scan"), peer)
        let base = await peer.seed(path: "Deleted.txt", bytes: Data("base".utf8))
        let scan = try await adapter.catalog.beginScan()
        try await adapter.catalog.stage([base.observation], in: scan)
        try await adapter.catalog.completeScan(scan)
        let item = try await adapter.catalog.children().items[0]
        let input = try MutationInput(item: WriteTemplate(id: item.id, name: item.entry.name),
            fields: [.contents], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(base.observation.contentVersion.utf8),
                                                  metadataVersion: Data(base.observation.metadataVersion.utf8)))
        await peer.remove("Deleted.txt")
        let recovered = try await adapter.write(input, create: false, progress: Progress(totalUnitCount: 1))
        let remoteHash = await peer.hash(recovered.entry.name)
        try mutationCheck(recovered.id == item.id && recovered.entry.name.contains("(conflict ") &&
            remoteHash == MutationPeer.hash(bytes), "A remote delete discarded or misidentified the delayed dirty upload")
        try mutationCheck(await peer.stat("Deleted.txt") == nil, "Recovery fabricated the deleted remote original")
        print("PASS a delayed dirty callback after remote disappearance recovers verified bytes as a sibling with its original Finder ID")

        let tombstonePeer = MutationPeer()
        let tombstoneRoot = root.appendingPathComponent("after-scan")
        let tombstone = try MutationTests.fixture(tombstoneRoot, tombstonePeer)
        let tombstoneBase = await tombstonePeer.seed(path: "Retired.txt", bytes: Data("base".utf8))
        let first = try await tombstone.catalog.beginScan()
        try await tombstone.catalog.stage([tombstoneBase.observation], in: first)
        try await tombstone.catalog.completeScan(first)
        let retired = try await tombstone.catalog.children().items[0]
        await tombstonePeer.remove("Retired.txt")
        let vanished = try await tombstone.catalog.beginScan()
        try await tombstone.catalog.completeScan(vanished)
        let retiredInput = try MutationInput(item: WriteTemplate(id: retired.id, name: retired.entry.name),
            fields: [.contents], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(tombstoneBase.observation.contentVersion.utf8),
                                                  metadataVersion: Data(tombstoneBase.observation.metadataVersion.utf8)))
        var retainedPayload: UUID?
        for _ in 0..<3 {
            do {
                _ = try await tombstone.write(retiredInput, create: false, progress: Progress(totalUnitCount: 1))
                throw MutationTestFailure(message: "A tombstoned dirty edit was acknowledged without a NAS commit")
            } catch let error as NSError {
                try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue,
                                  "A tombstoned dirty edit returned a destructive noSuchItem error")
            }
            let plans = tombstone.staging.planKeys(limit: 8)
            try mutationCheck(plans.count == 1, "Retry created multiple recovery records for one dirty edit")
            let record = try tombstone.staging.load(plans[0])!.localRecovery!
            if let retainedPayload { try mutationCheck(retainedPayload == record.payload.id, "Retry replaced the retained payload") }
            retainedPayload = record.payload.id
            try mutationCheck(record.requestedName == "Retired.txt" && record.baseContent == retiredInput.baseContent &&
                (try Data(contentsOf: tombstone.staging.payloadURL(record.payload.id))) == bytes,
                "Recovery omitted requested metadata or retained different bytes")
        }
        let restarted = try MutationTests.fixture(tombstoneRoot, tombstonePeer)
        let report = await restarted.maintain()
        let calls = await tombstonePeer.counts()
        try mutationCheck(report.recoveryPending == 1 && calls.2 == 0 && (try Data(contentsOf: source)) == bytes,
                          "Restart hid pending recovery, made an unauthorized write, or changed the system source")
        print("PASS retired dirty Finder IDs retain one durable payload and requested metadata across retries and owner restart without noSuchItem")

        let racePeer = MutationPeer()
        let race = try MutationTests.fixture(root.appendingPathComponent("queued-race"), racePeer)
        let racedInput = try MutationInput(item: WriteTemplate(id: "queued-template", name: "Queued.txt"),
            fields: [.filename, .parentItemIdentifier, .contents], contents: source)
        await racePeer.failNextMutation(code: "not_found")
        do {
            _ = try await race.write(racedInput, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "An unconfirmed not_found upload was acknowledged")
        } catch let error as NSError {
            try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue,
                              "A post-enqueue dirty upload exposed destructive noSuchItem")
        }
        let queued = try await race.catalog.replayableOperations()[0]
        try mutationCheck(queued.state == .uncertain && queued.intent.payload != nil &&
            FileManager.default.fileExists(atPath: race.staging.payloadURL(queued.intent.payload!.id).path),
            "An unconfirmed missing-path result lost the canonical dirty payload")
        let retried = try await race.write(racedInput, create: true, progress: Progress(totalUnitCount: 1))
        try mutationCheck(await racePeer.hash(retried.entry.name) == MutationPeer.hash(bytes),
                          "Preserving a missing-path race prevented a later verified retry")
        print("PASS post-enqueue missing-path races retain dirty bytes and never return noSuchItem before a verified retry")
        return 3
    }
}
