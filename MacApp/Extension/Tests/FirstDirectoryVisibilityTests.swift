import Foundation
import Darwin
import MyDriveCore

private actor VisibilityPause {
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { waiting = $0 } } }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

private actor VisibilityChild {
    var pid: Int32?
    var finished = false
    var unexpected = false
    func started(_ value: Int32) { pid = value }
    func ended(unexpected value: Bool) { finished = true; unexpected = value }
}

enum FirstDirectoryVisibilityTests {
    private static func require(_ condition: Bool) throws {
        if !condition { throw CocoaError(.fileReadCorruptFile) }
    }

    private static func waitForCount(_ count: Int, in signal: FirstDirectoryVisibility) async throws {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        while await signal.waitingCount != count {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            await Task.yield()
        }
    }

    static func run() async throws -> Int {
        let signal = FirstDirectoryVisibility()
        let cancelled = Task { try await signal.wait() }
        let peer = Task { try await signal.wait() }
        try await waitForCount(2, in: signal)
        cancelled.cancel()
        do { try await cancelled.value; throw CocoaError(.fileReadCorruptFile) }
        catch is CancellationError {}
        try await waitForCount(1, in: signal)
        await signal.resolve(.success(()))
        try await peer.value
        await signal.resolve(.failure(CocoaError(.fileReadUnknown)))
        try await signal.wait() // A late terminal failure cannot revoke committed visibility.
        print("PASS first-visible waiter cancellation detaches only that waiter and first commit wins over late failure")

        let bounded = FirstDirectoryVisibility()
        let waiters = (0..<128).map { _ in Task { try await bounded.wait() } }
        try await waitForCount(128, in: bounded)
        do { try await bounded.wait(); throw CocoaError(.fileReadCorruptFile) }
        catch let error as CocoaError where error.code == .fileLocking {}
        await bounded.resolve(.failure(CocoaError(.fileReadUnknown)))
        for waiter in waiters {
            do { try await waiter.value; throw CocoaError(.fileReadCorruptFile) }
            catch let error as CocoaError where error.code == .fileReadUnknown {}
        }
        try require(await bounded.waitingCount == 0)
        print("PASS first-visible rendezvous has bounded waiters and terminal failure drains every continuation")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try Catalog(databaseURL: root.appendingPathComponent("catalog.sqlite"))
        try await catalog.setConnectionState(.offline)
        let directory = RemoteEntry(name: "", kind: .directory, contentVersion: "held", metadataVersion: "held",
            objectIdentity: RemoteObjectIdentity(indexNumber: 10, createdFiletime: 20))
        let entries = (0..<160).map { index in
            RemoteEntry(name: String(format: "file-%03d", index), kind: .file,
                contentVersion: "v", metadataVersion: "m", size: 1,
                objectIdentity: RemoteObjectIdentity(indexNumber: UInt64(index + 100), createdFiletime: 30))
        }
        let pause = VisibilityPause(), visible = FirstDirectoryVisibility()
        let refresh = CatalogRefresh(catalog: catalog, publication: CatalogPublication(), list: { _, page in
            try await page(directory, Array(entries.prefix(128)))
            await pause.wait()
            try await page(directory, Array(entries.suffix(32)))
            return directory
        }, resolve: { _ in }, notify: {}, checkActive: { try Task.checkCancellation() }, becameVisible: { await visible.resolve(.success(())) })
        let running = Task { try await refresh.run(parentID: Catalog.rootID, path: "") }
        try await visible.wait()
        try require(try await catalog.hasPublishedChildren())
        try require(!(try await catalog.hasCompletedScan(of: Catalog.rootID)))
        try require(try await catalog.connectionState() == .offline)
        let first = try await catalog.children(limit: 1)
        let firstID = first.items[0].id
        try require(first.nextCursor != nil)
        await pause.release()
        _ = try await running.value
        try require(try await catalog.children(limit: 128).items[0].id == firstID)
        try require(try await catalog.children(limit: 128).items.count == 128)
        try require(try await catalog.hasCompletedScan(of: Catalog.rootID))
        try require(try await catalog.connectionState() == .online)
        do { _ = try await catalog.children(after: first.nextCursor, limit: 1); throw CocoaError(.fileReadCorruptFile) }
        catch CatalogError.staleCursor {}
        print("PASS real refresh exposes canonical prefix before EOF without online/completion and preserves IDs with truthful cursor expiry")
        let registry = ProviderTasks(), child = VisibilityChild(), helperVisible = FirstDirectoryVisibility()
        _ = registry.run { _ in
            var unexpected = false
            do {
                try await HelperOperation.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "trap '' INT TERM; printf '%s\\n' \"$$\"; while :; do :; done"], input: Data()) { frame in
                        guard let pid = Int32(String(decoding: frame, as: UTF8.self)) else { throw CocoaError(.fileReadCorruptFile) }
                        await child.started(pid)
                        await helperVisible.resolve(.success(()))
                    }
                unexpected = true
            } catch is CancellationError {} catch { unexpected = true }
            await child.ended(unexpected: unexpected)
        }
        try await helperVisible.wait()
        try require(await child.finished == false)
        let draining = registry.invalidate()
        for operation in draining { await operation.value }
        guard let pid = await child.pid else { throw CocoaError(.fileReadCorruptFile) }
        let ended = await child.finished, unexpected = await child.unexpected
        try require(ended && !unexpected)
        try require(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
        print("PASS early visibility does not detach a helper: registry cancellation drains and reaps before owner release")
        try await failedPrefixIsRetried(root: root)
        return 5
    }

    private static func failedPrefixIsRetried(root: URL) async throws {
        let database = root.appendingPathComponent("failed-prefix.sqlite")
        let catalog = try Catalog(databaseURL: database)
        let directory = RemoteEntry(name: "Nested", kind: .directory, contentVersion: "held", metadataVersion: "held",
            objectIdentity: .init(indexNumber: 2_000, createdFiletime: 2_001))
        let initial = try await catalog.beginScan()
        try await catalog.stage([directory], in: initial)
        try await catalog.completeScan(initial)
        guard let parent = try await catalog.child(named: directory.name, in: Catalog.rootID) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let early = RemoteEntry(name: "early", kind: .file, contentVersion: "early", metadataVersion: "early", size: 1,
            objectIdentity: .init(indexNumber: 2_002, createdFiletime: 2_003))
        let late = RemoteEntry(name: "late", kind: .file, contentVersion: "late", metadataVersion: "late", size: 1,
            objectIdentity: .init(indexNumber: 2_004, createdFiletime: 2_005))
        let visible = FirstDirectoryVisibility()
        let partial = CatalogRefresh(catalog: catalog, publication: CatalogPublication(), list: { path, page in
            guard path == "Nested" else { throw CocoaError(.fileReadCorruptFile) }
            try await page(directory, [early])
            throw SMBClientError.serverUnreachable
        }, resolve: { _ in throw CocoaError(.fileReadCorruptFile) },
           notify: { throw CocoaError(.fileReadCorruptFile) }, checkActive: { try Task.checkCancellation() },
           becameVisible: { await visible.resolve(.success(())) })
        let failed = Task { try await partial.run(parentID: parent.id, path: "Nested") }
        try await visible.wait() // The native caller has already received usable positives.
        do { _ = try await failed.value; throw CocoaError(.fileReadCorruptFile) }
        catch SMBClientError.serverUnreachable {}
        guard let published = try await catalog.child(named: early.name, in: parent.id) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try require(!(try await catalog.hasCompletedScan(of: parent.id)))
        try require(try await catalog.connectionState() == .offline)
        let reopened = try Catalog(databaseURL: database)
        // This is exactly the existing coordinator's periodic/reconnect query;
        // incomplete publication must not disappear with the abandoned scan.
        let known = try await reopened.observedDirectories(limit: 128)
        try require(known.map(\.id) == [parent.id])
        try require(!(try await reopened.hasCompletedScan(of: parent.id)))
        try require(try await reopened.child(named: early.name, in: parent.id)?.id == published.id)
        let notified = FirstDirectoryVisibility()
        for model in known {
            guard let path = try await reopened.relativePath(id: model.id) else { throw CocoaError(.fileReadCorruptFile) }
            let retry = CatalogRefresh(catalog: reopened, publication: CatalogPublication(), list: { requested, page in
                guard requested == "Nested" else { throw CocoaError(.fileReadCorruptFile) }
                try await page(directory, [early, late])
                return directory
            }, resolve: { _ in }, notify: { await notified.resolve(.success(())) },
               checkActive: { try Task.checkCancellation() })
            _ = try await retry.run(parentID: model.id, path: path)
        }
        try await notified.wait()
        try require(try await reopened.hasCompletedScan(of: parent.id))
        try require(try await reopened.connectionState() == .online)
        try require(try await reopened.children(of: parent.id).items.count == 2)
        try require(try await reopened.child(named: early.name, in: parent.id)?.id == published.id)
        print("PASS failed nested prefix survives restart in the known-directory refresh query and terminal retry preserves IDs and wakes Finder")
    }
}
