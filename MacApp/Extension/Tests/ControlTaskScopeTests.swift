import FileProvider
import Foundation

private enum ControlScopeFailure: Error { case failed(String) }

private actor ControlScopeLatch {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        open = true
        let pending = waiting; waiting.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private actor ControlScopeFacts {
    var pages = 0
    var evictions = 0
    var aCancelled = false
    var bStarted = false
    var bCancelled: Bool?
    var drainingStarted = false
    var leaseReleased = false
    func page() { pages += 1 }
    func evict() { evictions += 1 }
    func cancelA() { aCancelled = true }
    func startB() { bStarted = true }
    func finishB(cancelled: Bool) { bCancelled = cancelled }
    func startDraining() { drainingStarted = true }
    func releaseLease() { leaseReleased = true }
    func bothStarted() -> Bool { evictions == 1 && bStarted }
    func connectionResultIsCorrect() -> Bool { pages == 1 && evictions == 1 && bCancelled == false }
}

@MainActor enum ControlTaskScopeTests {
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw ControlScopeFailure.failed(message) }
    }
    private static func until(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await ready()) {
            if ContinuousClock.now >= deadline { throw ControlScopeFailure.failed("Task scope test did not reach its checkpoint") }
            await Task.yield()
        }
    }

    static func run() async throws -> Int {
        try await connectionCancellation()
        try await shutdownDrain()
        try await closedScopes()
        return 3
    }

    private static func connectionCancellation() async throws {
        let registry = ProviderTasks()
        let a = registry.makeScope(), b = registry.makeScope()
        let native = ControlScopeLatch(), releaseB = ControlScopeLatch()
        let facts = ControlScopeFacts()
        _ = a.run { _ in
            do {
                let pass = RemovalEviction()
                _ = try await pass.run(preparePolicy: {}, checkActive: { try Task.checkCancellation() }, readPage: { _, _ in
                    await facts.page()
                    return .init(items: [.init(identifier: "leaf", kind: .leaf)], next: NSFileProviderPage(Data("more".utf8)))
                }, evict: { _ in
                    await facts.evict()
                    try await RemovalEvictionRequest.run(until: pass.requestDeadline) { finish in
                        Task { await native.wait(); finish(nil) }
                    }
                    return .evicted
                })
            } catch {
                if Task.isCancelled { await facts.cancelA() }
            }
        }
        _ = b.run { _ in
            await facts.startB()
            await releaseB.wait()
            await facts.finishB(cancelled: Task.isCancelled)
        }
        try await until { await facts.bothStarted() }
        a.invalidate()
        try await until { await facts.aCancelled }
        await native.release() // Native work can reply after local cancellation.
        await releaseB.release()
        try await until { await facts.bCancelled != nil }
        try check(await facts.connectionResultIsCorrect(),
                  "Closing connection A started future removal work or cancelled B")
        for task in registry.invalidate() { await task.value }
        print("PASS XPC scope cancellation stops future pages/evictions without cancelling another connection")
    }

    private static func shutdownDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owner")
        let lease = try DomainOwnerLease(at: url)
        defer { lease.release() }
        let registry = ProviderTasks(), release = ControlScopeLatch(), facts = ControlScopeFacts()
        let scope = registry.makeScope()
        _ = scope.run { _ in
            await facts.startDraining()
            await release.wait() // Models an already-accepted, uncancellable operation.
        }
        try await until { await facts.drainingStarted }
        scope.invalidate() // The XPC connection disappears before global shutdown.
        let pending = registry.invalidate()
        try check(pending.count == 1 && registry.invalidate().count == 1,
                  "Closed connection's draining task disappeared from the shutdown barrier")
        let shutdown = Task {
            for task in pending { await task.value }
            lease.release()
            await facts.releaseLease()
        }
        do {
            let duplicate = try DomainOwnerLease(at: url)
            duplicate.release()
            throw ControlScopeFailure.failed("Shutdown released ownership before draining a closed connection")
        } catch let error as CocoaError { try check(error.code == .fileLocking, "Unexpected owner contention") }
        try check(await !facts.leaseReleased, "Shutdown barrier completed before its in-flight task")
        await release.release()
        await shutdown.value
        let replacement = try DomainOwnerLease(at: url)
        replacement.release()
        print("PASS provider shutdown retains removed-connection task handles and domain ownership until completion")
    }

    private static func closedScopes() async throws {
        for invalidateGlobal in [false, true] {
            let registry = ProviderTasks()
            let scope = registry.makeScope()
            if invalidateGlobal { _ = registry.invalidate() } else { scope.invalidate() }
            let cancelled: Bool = await withCheckedContinuation { continuation in
                _ = scope.run { _ in continuation.resume(returning: Task.isCancelled) }
            }
            try check(cancelled, "Closed connection or shutdown accepted an uncancelled request")
            for task in registry.invalidate() { await task.value }
        }
        print("PASS closed connection and shutdown gates reject future uncancelled requests")
    }
}
