import FileProvider
import Foundation
import MyDriveCore
import Darwin

private actor PreparedUploadObservation {
    var values: [(String, String?, Int64?, Int)] = []
    func record(_ id: String, _ path: String?, _ bytes: Int64?, calls: Int) { values.append((id, path, bytes, calls)) }
}

extension MutationTests {
    static func creationReplay() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)
        let template = WriteTemplate(id: "os-stable-template", name: "New.txt")
        let input = try MutationInput(item: template, fields: [.filename, .parentItemIdentifier, .contents], contents: source)
        try mutationCheck(input.contentByteCount == Int64(bytes.count), "Queued upload guessed SDK progress units instead of source bytes")

        let peer = MutationPeer(), observed = PreparedUploadObservation()
        let recovery = try fixture(root.appendingPathComponent("recovery"), peer, prepared: { id, path, bytes in
            await observed.record(id, path, bytes, calls: peer.counts().2)
        })
        await peer.loseReply()
        do {
            _ = try await recovery.write(input, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Lost reply was acknowledged as committed")
        } catch SMBClientError.serverUnreachable {}
        let staged = try await recovery.catalog.replayableOperations()
        let preparation = await observed.values
        try mutationCheck(preparation.count == 1 && preparation[0].0 == staged[0].intent.itemID && preparation[0].0 != input.id &&
            preparation[0].1 == "New.txt" && preparation[0].2 == Int64(bytes.count) && preparation[0].3 == 0,
            "Canonical identity and bytes were not observed before the failed remote upload")
        try mutationCheck(staged.count == 1 && staged[0].state == .uncertain, "Uncertain upload was not durable")
        try mutationCheck(FileManager.default.fileExists(atPath: recovery.staging.payloadURL(staged[0].intent.payload!.id).path),
                          "Uncertain callback discarded its only durable payload")
        let restarted = try fixture(root.appendingPathComponent("recovery"), peer)
        let created = try await restarted.write(input, create: true, progress: Progress(totalUnitCount: 1))
        let originalCounts = await peer.counts()
        let replayed = try await restarted.write(input, create: true, progress: Progress(totalUnitCount: 1))
        let replayCounts = await peer.counts()
        try mutationCheck(created.id == replayed.id && replayCounts.2 == originalCounts.2,
                          "Completed OS callback replay made another network request")
        try mutationCheck(originalCounts.0 == 1 && originalCounts.1 == 1 && (try Data(contentsOf: source)) == bytes,
                          "Crash recovery duplicated publication or modified the OS-owned source")
        try mutationCheck(await peer.hash("New.txt") == MutationPeer.hash(bytes), "Recovered remote bytes differ")
        print("PASS upload lost-reply recovery, stable create binding, retained payload and completed callback replay")
        let laterSource = root.appendingPathComponent("newer-create.txt")
        let laterBytes = Data("newer local edit before original creation acknowledgement".utf8)
        try laterBytes.write(to: laterSource)
        let newerCreate = try MutationInput(item: template, fields: [.filename, .parentItemIdentifier, .contents], contents: laterSource)
        let newerCreated = try await restarted.write(newerCreate, create: true, progress: Progress(totalUnitCount: 1))
        try mutationCheck(newerCreated.id == created.id && newerCreated.entry.name.contains("(conflict "),
                          "Newer create replay could not reuse its existing durable provider binding")
        try mutationCheck(await peer.hash(newerCreated.entry.name) == MutationPeer.hash(laterBytes), "Newer unacknowledged creation lost bytes")
        let dataless = try MutationInput(item: template, fields: [.filename, .parentItemIdentifier, .contents], contents: nil)
        let adopted = try await restarted.write(dataless, create: true, progress: Progress(totalUnitCount: 1))
        try mutationCheck(adopted.id == created.id, "Dataless replay lost its exact known template binding")
        print("PASS newer unacknowledged create bytes preserve both versions and dataless replay adopts only its known binding")
        return 2
    }

    static func allocatedResume() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)
        let template = WriteTemplate(id: "os-stable-template", name: "New.txt")
        let input = try MutationInput(item: template, fields: [.filename, .parentItemIdentifier, .contents], contents: source)

        let allocatedPeer = MutationPeer()
        let allocatedRoot = root.appendingPathComponent("allocated-resume")
        let allocated = try fixture(allocatedRoot, allocatedPeer)
        await allocatedPeer.useAllocatedReceipts(interruptWrite: true)
        do {
            _ = try await allocated.write(input, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Interrupted allocated upload was acknowledged")
        } catch SMBClientError.serverUnreachable {}
        let allocatedOperation = try await allocated.catalog.replayableOperations()[0]
        let allocatedPlan = try allocated.staging.load(allocatedOperation.intent.idempotencyKey)!
        let beforeAllocatedCounts = await allocatedPeer.counts()
        try mutationCheck(allocatedPlan.steps[0].request.receipt.staged?.phase == .allocated &&
            allocatedPlan.steps[0].request.receipt.staged?.entry.bytes == 0 && beforeAllocatedCounts.0 == 1,
            "Bytes were sent without a durable allocation receipt")
        let resumedAllocated = try fixture(allocatedRoot, allocatedPeer)
        _ = try await resumedAllocated.write(input, create: true, progress: Progress(totalUnitCount: 1))
        let allocatedCounts = await allocatedPeer.counts()
        let allocatedHash = await allocatedPeer.hash("New.txt")
        try mutationCheck(allocatedCounts.0 == 1 && allocatedCounts.1 == 1 && allocatedHash == MutationPeer.hash(bytes),
                          "Restart did not rewrite and verify the same allocated object")
        print("PASS interrupted upload retains its allocated identity and restart rewrites that same stage before publication")
        return 1
    }

    static func allocatedCancellation() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)
        let template = WriteTemplate(id: "os-stable-template", name: "New.txt")
        let input = try MutationInput(item: template, fields: [.filename, .parentItemIdentifier, .contents], contents: source)

        let allocationCancelPeer = MutationPeer()
        let allocationCancelLatch = CancellationLatch()
        let allocationCancel = try fixture(root.appendingPathComponent("allocation-cancel"), allocationCancelPeer,
            check: { try await allocationCancelLatch.check() })
        await allocationCancelPeer.useAllocatedReceipts()
        await allocationCancelPeer.cancelAfterStage(allocationCancelLatch)
        do {
            _ = try await allocationCancel.write(input, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Cancelled allocation sent file bytes")
        } catch is CancellationError {}
        let cancelledAllocationCounts = await allocationCancelPeer.counts()
        try mutationCheck(cancelledAllocationCounts.0 == 1 && cancelledAllocationCounts.1 == 0,
                          "Allocation cancellation did not stop before publication")
        await allocationCancelLatch.set(false)
        await allocationCancelPeer.cancelAfterStage(nil)
        _ = try await allocationCancel.write(input, create: true, progress: Progress(totalUnitCount: 1))
        try mutationCheck(await allocationCancelPeer.counts().0 == 1, "Cancellation restarted allocation instead of resuming its receipt")
        print("PASS cancellation after persisted allocation stops before bytes and retry resumes the acknowledged stage")
        return 1
    }

    static func lostAllocationReply() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)
        let template = WriteTemplate(id: "os-stable-template", name: "New.txt")
        let input = try MutationInput(item: template, fields: [.filename, .parentItemIdentifier, .contents], contents: source)

        let lostAllocationPeer = MutationPeer()
        let lostAllocationRoot = root.appendingPathComponent("allocation-ack")
        let lostAllocation = try fixture(lostAllocationRoot, lostAllocationPeer)
        await lostAllocationPeer.useAllocatedReceipts(lostReplies: 1)
        do {
            _ = try await lostAllocation.write(input, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Lost allocation ACK was acknowledged")
        } catch SMBClientError.serverUnreachable {}
        let lostAllocationRetry = try fixture(lostAllocationRoot, lostAllocationPeer)
        _ = try await lostAllocationRetry.write(input, create: true, progress: Progress(totalUnitCount: 1))
        let uncertainPaths = await lostAllocationRetry.maintain()
        let lossCounts = await lostAllocationPeer.counts()
        try mutationCheck(lossCounts.0 == 2 && lossCounts.1 == 1 && uncertainPaths.retained == 1 &&
            lostAllocationRetry.staging.planKeys(limit: 8, after: nil).count == 1,
            "Lost-ACK retry adopted/removed an unknown stage or forgot its retained path")
        print("PASS lost allocation acknowledgement rotates one fresh wire intent while preserving the unowned stage path after commit")
        return 1
    }

    static func allocationBudget() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)
        let template = WriteTemplate(id: "os-stable-template", name: "New.txt")
        let input = try MutationInput(item: template, fields: [.filename, .parentItemIdentifier, .contents], contents: source)

        let exhaustedPeer = MutationPeer()
        let exhaustedRoot = root.appendingPathComponent("allocation-budget")
        await exhaustedPeer.useAllocatedReceipts(lostReplies: 3)
        for attempt in 0..<3 {
            let owner = try fixture(exhaustedRoot, exhaustedPeer)
            do {
                _ = try await owner.write(input, create: true, progress: Progress(totalUnitCount: 1))
                throw MutationTestFailure(message: "Lost allocation reply \(attempt) did not fail")
            } catch SMBClientError.serverUnreachable {}
        }
        for _ in 0..<2 {
            let owner = try fixture(exhaustedRoot, exhaustedPeer)
            do {
                _ = try await owner.write(input, create: true, progress: Progress(totalUnitCount: 1))
                throw MutationTestFailure(message: "An exhausted allocation budget was reset by restart")
            } catch let error as NSError {
                try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue,
                                  "Exhausted allocation did not report preserving recovery")
            }
        }
        let exhausted = try fixture(exhaustedRoot, exhaustedPeer)
        let exhaustedCounts = await exhaustedPeer.counts()
        let exhaustedReport = await exhausted.maintain()
        try mutationCheck(exhaustedCounts.0 == 3 && exhaustedCounts.1 == 0 && exhaustedReport.retained == 3 && exhaustedReport.recoveryPending == 1,
                          "Fresh wire retries were unbounded or ambiguous paths were not retained")
        print("PASS lost-allocation retry budget survives owner restart and never writes or deletes unknown stages")
        return 1
    }

    static func preparedCancellation() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)
        let template = WriteTemplate(id: "os-stable-template", name: "New.txt")
        let input = try MutationInput(item: template, fields: [.filename, .parentItemIdentifier, .contents], contents: source)

        let cancellationPeer = MutationPeer()
        let latch = CancellationLatch()
        let cancellation = try fixture(root.appendingPathComponent("cancel"), cancellationPeer, check: { try await latch.check() })
        await cancellationPeer.cancelAfterStage(latch)
        do {
            _ = try await cancellation.write(input, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Cancelled prepared upload returned success")
        } catch is CancellationError {}
        let pending = try await cancellation.catalog.replayableOperations()
        let cancelledTarget = await cancellationPeer.stat("New.txt")
        try mutationCheck(pending.count == 1 && cancelledTarget == nil,
                          "Cancellation after preparation unexpectedly published the file")
        await latch.set(false); await cancellationPeer.cancelAfterStage(nil)
        _ = try await cancellation.write(input, create: true, progress: Progress(totalUnitCount: 1))
        try mutationCheck((await cancellationPeer.counts()).0 == 1, "Cancellation replay uploaded a second stage")
        print("PASS cancellation after durable stage receipt resumes the same upload without a second stage")
        return 1
    }

}
