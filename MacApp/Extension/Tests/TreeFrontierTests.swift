import FileProvider
import Foundation
import MyDriveCore

/// Suspends real MutationPeer RPCs; no substitute journal, transport or clock.
actor TreeFrontierProbe {
    private let holdLimit: Int
    private var active = 0
    private var peak = 0
    private var held: [String] = []
    private var waiters: [String: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<String> = []
    private var began: [String] = []
    private var released: [String] = []
    private var failed = 0
    private var failureKey: String?
    init(holdLimit: Int = 4) { self.holdLimit = holdLimit }

    func before(_ request: SMBMutationRequest, reconcile: Bool) async throws {
        guard request.tree_scope != nil else { return }
        active += 1; peak = max(peak, active)
        guard request.kind == .createFile, !reconcile, request.receipt.staged == nil, held.count < holdLimit else { return }
        let key = request.operation_id
        held.append(key); began.append(key)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled.remove(key) != nil { continuation.resume(throwing: CancellationError()) }
                else { waiters[key] = continuation }
            }
        } onCancel: { Task { await self.cancel(key) } }
        if failureKey == key { throw SMBClientError.serverUnreachable }
    }

    func after(_ request: SMBMutationRequest, failed: Bool) async {
        guard request.tree_scope != nil else { return }
        if failed {
            // Models a helper's required kill/reap unwind after cancellation.
            await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
            self.failed += 1
        }
        active -= 1
    }

    private func cancel(_ key: String) {
        if let continuation = waiters.removeValue(forKey: key) { continuation.resume(throwing: CancellationError()) }
        else { cancelled.insert(key) }
    }

    func release(_ key: String) {
        released.append(key)
        waiters.removeValue(forKey: key)?.resume()
    }

    func fail(_ key: String) { failureKey = key; release(key) }

    func snapshot() -> (active: Int, peak: Int, began: [String], released: [String], failed: Int) {
        (active, peak, began, released, failed)
    }
}

enum TreeFrontierTests {
    static func run() async throws -> Int {
        try await overlapAndReverseOrder()
        try await cancellationDrainsAndReplays()
        try await failureCancelsSiblings()
        try await configuredEightWorkers()
        return 4
    }

    private static func awaitFour(_ probe: TreeFrontierProbe) async throws -> [String] {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let state = await probe.snapshot()
            if state.began.count == 4 { return state.began }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MutationTestFailure(message: "Four independent tree children never overlapped")
    }

    private static func configuredEightWorkers() async throws {
        let probe = TreeFrontierProbe(holdLimit: 8)
        let fixture = try await TreeImportTests.fixture(wide: true, probe: probe, preferences: {
            var preferences = UserPreferences(); preferences.simultaneousTransfers = 8; return preferences
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let progress = Progress(totalUnitCount: 1)
        let task = Task { try await fixture.owner.write(fixture.input, create: true, progress: progress) }
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            while await probe.snapshot().began.count < 8 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let state = await probe.snapshot()
            try mutationCheck(state.active == 8 && state.peak == 8 && state.began.count == 8,
                              "The configured eight-transfer setting did not reach eight bounded workers")
            for key in state.began { await probe.release(key) }
            _ = try await task.value
            let final = await probe.snapshot()
            try mutationCheck(progress.isFinished && final.peak == 8,
                              "The configured frontier exceeded its cap or failed to complete")
        } catch { task.cancel(); _ = await task.result; throw error }
        print("PASS the configured eight-transfer setting drives eight real overlapping mutation adapters through complete publication")
    }

    private static func awaitReceipt(_ key: String, fixture: TreeImportTests.Fixture) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if try await fixture.owner.catalog.operation(key: UUID(uuidString: key)!)?.state == .completed { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MutationTestFailure(message: "Released tree child did not record its durable receipt")
    }

    private static func overlapAndReverseOrder() async throws {
        let probe = TreeFrontierProbe(), fixture = try await TreeImportTests.fixture(wide: true, probe: probe)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let progress = Progress(totalUnitCount: 1)
        let task = Task { try await fixture.owner.write(fixture.input, create: true, progress: progress) }
        do {
            let keys = try await awaitFour(probe)
            let initial = await probe.snapshot()
            try mutationCheck(initial.active == 4 && initial.peak == 4,
                              "Fixed frontier did not overlap exactly four held helper operations")
            var lastProgress = progress.completedUnitCount
            for key in keys.reversed() {
                await probe.release(key)
                try await awaitReceipt(key, fixture: fixture)
                try mutationCheck(progress.completedUnitCount >= lastProgress,
                                  "Reverse-order worker receipt moved aggregate progress backwards")
                lastProgress = progress.completedUnitCount
            }
            let result = try await task.value
            let final = await probe.snapshot(), paths = await fixture.peer.treePaths()
            try mutationCheck(final.active == 0 && final.peak == 4 && final.released == keys.reversed() &&
                paths.count == 105 && result.entry.name == "Imported folder" && progress.isFinished,
                "Four-worker import leaked work, exceeded its cap or published an incomplete tree")
        } catch { task.cancel(); _ = await task.result; throw error }
        print("PASS fixed tree frontier overlaps four RPCs, caps all waves, and accepts reverse-order durable receipts")
    }

    private static func cancellationDrainsAndReplays() async throws {
        let probe = TreeFrontierProbe(), fixture = try await TreeImportTests.fixture(wide: true, probe: probe)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let progress = Progress(totalUnitCount: 1)
        let task = Task { try await fixture.owner.write(fixture.input, create: true, progress: progress) }
        do {
            let keys = try await awaitFour(probe)
            await probe.release(keys[3])
            try await awaitReceipt(keys[3], fixture: fixture)
            task.cancel()
            do { _ = try await task.value; throw MutationTestFailure(message: "Cancelled frontier was acknowledged") }
            catch is CancellationError {} catch let error as NSError {
                try mutationCheck(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue,
                                  "Cancelled frontier returned a different failure")
            }
            let drained = await probe.snapshot()
            let rootID = try await fixture.owner.catalog.providerID(forCreateTemplate: fixture.input.id)
            let status = try await fixture.owner.catalog.treeImportStatus(rootID: rootID)
            let receipt = try await fixture.owner.catalog.operation(key: UUID(uuidString: keys[3])!)
            let visible = try await fixture.owner.catalog.children()
            try mutationCheck(drained.active == 0 && drained.failed >= 3 && receipt?.state == .completed &&
                status?.phase == .frozen && !progress.isFinished && visible.items.isEmpty,
                "Cancellation returned before sibling unwind or lost a confirmed private receipt")
            try FileManager.default.removeItem(at: fixture.source)
            let restarted = try TreeImportTests.owner(fixture.root, peer: fixture.peer)
            let result = try await restarted.write(try TreeImportTests.request(contents: nil), create: true,
                                                    progress: Progress(totalUnitCount: 1))
            let finalReceipt = try await restarted.catalog.operation(key: UUID(uuidString: keys[3])!)
            let finalPaths = await fixture.peer.treePaths()
            try mutationCheck(result.id == rootID && finalReceipt?.attemptCount == receipt?.attemptCount &&
                finalPaths.count == 105,
                "Cancelled four-worker import duplicated a completed child or lost its durable input")
        } catch { task.cancel(); _ = await task.result; throw error }
        print("PASS cancelled tree frontier drains all children before return; restart reuses receipts and source-less durable input")
    }
    private static func failureCancelsSiblings() async throws {
        let probe = TreeFrontierProbe(), fixture = try await TreeImportTests.fixture(wide: true, probe: probe)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = Task { try await fixture.owner.write(fixture.input, create: true, progress: Progress(totalUnitCount: 1)) }
        do {
            let keys = try await awaitFour(probe)
            await probe.fail(keys[0])
            do { _ = try await task.value; throw MutationTestFailure(message: "Failed frontier was acknowledged") }
            catch let error as NSError {
                try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.serverUnreachable.rawValue,
                                  "Sibling cancellation obscured the original helper failure")
            }
            let drained = await probe.snapshot()
            let visible = try await fixture.owner.catalog.children()
            try mutationCheck(drained.active == 0 && drained.failed == 4 && visible.items.isEmpty,
                              "First helper failure did not cancel and drain the other three workers before returning")
        } catch { task.cancel(); _ = await task.result; throw error }
        print("PASS first helper failure cancels and drains sibling workers while preserving the original error")
    }

}
