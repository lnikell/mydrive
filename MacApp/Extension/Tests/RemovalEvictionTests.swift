import Darwin
import FileProvider
import Foundation
import MyDriveCore
import UniformTypeIdentifiers

private enum RemovalTestFailure: Error { case failed(String) }

private class RemovalNativeItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "fixture" }
    init(_ identifier: String) { itemIdentifier = NSFileProviderItemIdentifier(identifier) }
}

private final class RemovalTypedItem: RemovalNativeItem {
    let contentType: UTType
    init(_ identifier: String, type: UTType) { contentType = type; super.init(identifier) }
}

private final class RemovalRequestCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Error?) -> Void)?
    var started: Bool { lock.withLock { completion != nil } }
    func start(_ completion: @escaping @Sendable (Error?) -> Void) { lock.withLock { self.completion = completion } }
    func finish(_ error: (any Error)? = nil) { lock.withLock { completion }?(error) }
}

private actor RemovalLeafRetry {
    private var attempts: [String: Int] = [:]
    func attempt(_ id: String) throws {
        attempts[id, default: 0] += 1
        if attempts[id] == 1 { throw NSFileProviderError(.nonEvictable) }
    }
    func count(_ id: String) -> Int { attempts[id] ?? 0 }
}

@MainActor enum RemovalEvictionTests {
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw RemovalTestFailure.failed(message) }
    }
    private static func page(_ items: [MaterializedPage.Item], next: Bool = false) -> MaterializedPage.ResultPage {
        .init(items: items, next: next ? NSFileProviderPage(Data("next".utf8)) : nil)
    }

    static func run() async throws -> Int {
        try nativeKinds()
        try await leavesAndRefusals()
        try await policyAndServiceFailures()
        try await streamingAndPartialFailure()
        try await policyChanges()
        try await independentLeafWindows()
        try await deadlineAndLateReply()
        try await cancellationAndInvalidation()
        return 8
    }

    private static func nativeKinds() throws {
        let folder = MaterializedPage.Item(RemovalTypedItem("folder", type: .folder))
        let file = MaterializedPage.Item(RemovalTypedItem("file", type: .plainText))
        let opaque = MaterializedPage.Item(RemovalTypedItem("remote-directory", type: .item))
        let package = MaterializedPage.Item(RemovalTypedItem("native-package", type: .package))
        let absent = MaterializedPage.Item(RemovalNativeItem("missing-type"))
        try check(folder.kind == .container && file.kind == .leaf && opaque.kind == .leaf &&
                  package.kind == .leaf && absent.kind == .unknown,
                  "Native folder/leaf/unknown classification changed")
        print("PASS removal eligibility follows native item representation, including opaque package leaves")
    }

    private static func leavesAndRefusals() async throws {
        let items: [MaterializedPage.Item] = [
            .init(identifier: "folder", kind: .container), .init(identifier: "remote-directory", kind: .leaf),
            .init(identifier: "busy", kind: .leaf), .init(identifier: "dirty", kind: .leaf),
            .init(identifier: "pinned", kind: .leaf), .init(identifier: "unknown", kind: .unknown)
        ]
        var prepared = false
        var attempts: [String] = []
        let report = try await RemovalEviction().run(preparePolicy: { prepared = true }, checkActive: {}, readPage: { initial, _ in
            try check(prepared, "Enumeration preceded policy publication")
            try check(initial.rawValue.isEmpty, "Materialized enumeration did not start with empty Data")
            return page(items)
        }, evict: { id in
            attempts.append(id)
            if id == "busy" { throw POSIXError(.EBUSY) }
            if id == "dirty" { throw NSFileProviderError(.unsyncedEdits) }
            return id == "pinned" ? .keptDownloaded : .evicted
        })
        try check(attempts == ["remote-directory", "busy", "dirty", "pinned"] && report.completed == 1 &&
                  report.retained.count == 4 && report.failure == nil,
                  "Containers, unknown types or OS refusals were mishandled")
        print("PASS removal skips recursive containers and preserves busy, dirty, pinned and unknown leaves")
    }

    private static func streamingAndPartialFailure() async throws {
        var calls = 0, offset = 0
        var evictions = 0
        let streamed = try await RemovalEviction().run(preparePolicy: {}, checkActive: {}, readPage: { _, _ in
            calls += 1
            let end = min(offset + 50, 5_001)
            let items = (offset..<end).map { MaterializedPage.Item(identifier: "\($0)", kind: .leaf) }
            offset = end
            return .init(items: [.init(identifier: "folder-\(calls)", kind: .container)] + items,
                next: end < 5_001 ? NSFileProviderPage(Data("\(end)".utf8)) : nil)
        }, evict: { _ in evictions += 1; return .evicted })
        try check(calls == 101 && evictions == 5_001 && streamed.completed == 5_001 && streamed.failure == nil,
                  "Streaming stopped at an arbitrary page/item cap")
        var pages = 0
        let empty = try await RemovalEviction().run(preparePolicy: {}, checkActive: {}, readPage: { _, _ in
            pages += 1; return page([], next: true)
        }, evict: { _ in throw RemovalTestFailure.failed("Empty pages started eviction") })
        try check(pages == 2 && empty.failure != nil, "Repeated native continuation did not fail closed")
        var partialPages = 0
        let expected = CocoaError(.fileReadUnknown) as NSError
        let partial = try await RemovalEviction().run(preparePolicy: {}, checkActive: {}, readPage: { _, _ in
            partialPages += 1
            if partialPages == 2 { throw expected }
            return page([.init(identifier: "first", kind: .leaf)], next: true)
        }, evict: { _ in .evicted })
        let actual = partial.failure as NSError?
        try check(partial.completed == 1 && actual?.domain == expected.domain && actual?.code == expected.code,
                  "Incomplete enumeration lost partial progress or native cause")
        var reachedPage = false
        let failedPolicy = try await RemovalEviction().run(preparePolicy: { throw CocoaError(.fileWriteNoPermission) },
            checkActive: {}, readPage: { _, _ in reachedPage = true; return page([]) }, evict: { _ in .evicted })
        try check(!reachedPage && failedPolicy.failure != nil, "Failed policy publication started eviction")
        print("PASS 5001 leaves stream over101 bounded pages; incomplete policy/enumeration retains partial results")
    }

    private static func policyAndServiceFailures() async throws {
        let pass = RemovalEviction()
        let policyError = CatalogError.invalidEntry
        var nativeAttempts = 0
        let policy = try await pass.run(preparePolicy: {}, checkActive: {}, readPage: { _, _ in
            page([.init(identifier: "first", kind: .leaf)])
        }, evict: { _ in
            try await pass.evict(isKeptDownloaded: { throw policyError }, checkActive: {}, attempt: { _ in
                throw RemovalTestFailure.failed("Failed policy read reached OS eviction")
            })
        })
        try check(policy.failure as? CatalogError == policyError && policy.retained.isEmpty,
                  "Catalog/policy read failure became a completed per-item retention")
        let failures: [NSError] = [NSFileProviderError(.providerNotFound) as NSError,
            NSFileProviderError(.serverUnreachable) as NSError, CocoaError(.xpcConnectionInterrupted) as NSError,
            NSError(domain: "OtherDomain", code: Int(EBUSY))]
        for expected in failures {
            let report = try await pass.run(preparePolicy: {}, checkActive: {}, readPage: { _, _ in
                page([.init(identifier: "first", kind: .leaf), .init(identifier: "unvisited", kind: .leaf)])
            }, evict: { _ in nativeAttempts += 1; throw expected })
            let actual = report.failure as NSError?
            try check(actual?.domain == expected.domain && actual?.code == expected.code && report.retained.isEmpty,
                      "Provider/service failure became a completed scan or lost its native cause")
        }
        try check(nativeAttempts == failures.count, "Systemic failure continued to unvisited leaves")
        print("PASS policy/Catalog and provider/service failures stop enumeration and require the incomplete-pass barrier")
    }

    private static func policyChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog(databaseURL: folder.appendingPathComponent("catalog.sqlite"))
        let scan = try await catalog.beginScan()
        try await catalog.stage((0..<130).map {
            RemoteEntry(name: "\($0).txt", kind: .file, contentVersion: "1", metadataVersion: "1", size: 1)
        }, in: scan)
        try await catalog.completeScan(scan)
        let files = try await catalog.children(limit: 200).items
        for file in files { try await catalog.setOfflinePolicy(.keepAvailable, for: file.id) }
        try await catalog.setOfflinePolicy(.keepAvailable, for: Catalog.rootID)
        let pass = RemovalEviction()
        try await pass.clearSelections(in: catalog, checkActive: {})
        try check(try await catalog.offlineSelections().isEmpty, "Explicit offline selections were not all cleared")
        for file in files { try check(try await catalog.offlinePolicy(for: file.id) == .onDemand, "Inherited pin survived removal preparation") }
        print("PASS bounded policy paging clears inherited and explicit Keep Downloaded selections")
    }

    private static func independentLeafWindows() async throws {
        let pass = RemovalEviction(requestTimeout: .milliseconds(300))
        let peer = RemovalLeafRetry()
        let report = try await pass.run(preparePolicy: {}, checkActive: {}, readPage: { _, _ in
            page([.init(identifier: "first", kind: .leaf), .init(identifier: "second", kind: .leaf)])
        }, evict: { id in
            try await pass.evict(isKeptDownloaded: { false }, checkActive: {}, attempt: { _ in try await peer.attempt(id) })
        })
        let first = await peer.count("first"), second = await peer.count("second")
        try check(first == 2 && second == 2 && report.completed == 2 && report.failure == nil,
                  "A later leaf inherited the expired retry/deadline window of an earlier leaf")
        print("PASS each leaf receives a fresh policy retry window within its own native deadline")
    }

    private static func deadlineAndLateReply() async throws {
        try await RemovalEvictionRequest.run(until: .now.advanced(by: .seconds(1))) { finish in
            DispatchQueue.global().async { @Sendable in
                finish(nil)
                finish(CocoaError(.fileReadUnknown))
            }
        }
        let pass = RemovalEviction(requestTimeout: .milliseconds(25))
        let callback = RemovalRequestCallback()
        var attempts = 0
        let started = ContinuousClock.now
        let report = try await pass.run(preparePolicy: {}, checkActive: {}, readPage: { _, _ in
            page([.init(identifier: "first", kind: .leaf), .init(identifier: "second", kind: .leaf)])
        }, evict: { _ in
            attempts += 1
            try await RemovalEvictionRequest.run(until: pass.requestDeadline) { callback.start($0) }
            return .evicted
        })
        callback.finish(); callback.finish(CocoaError(.fileReadUnknown))
        try check(attempts == 1 && report.completed == 0 && report.failure != nil &&
                  started.duration(to: .now) < .seconds(1), "Native wait exceeded deadline or continued work after timeout")
        var expiredStarted = false
        do {
            try await RemovalEvictionRequest.run(until: .now) { _ in expiredStarted = true }
            throw RemovalTestFailure.failed("Expired request returned success")
        } catch is RemovalEviction.Failure { }
        try check(!expiredStarted, "An expired deadline issued a native request")
        print("PASS per-request deadline bounds local native waits and ignores late duplicate replies")
    }

    private static func cancellationAndInvalidation() async throws {
        let callback = RemovalRequestCallback()
        let task = Task { @MainActor in
            try await RemovalEvictionRequest.run(until: .now.advanced(by: .seconds(10))) { callback.start($0) }
        }
        while !callback.started { await Task.yield() }
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do { try await task.value; throw RemovalTestFailure.failed("Cancelled request returned success") }
        catch is CancellationError { }
        callback.finish()
        try check(cancelledAt.duration(to: .now) < .seconds(1), "Cancellation waited for uncancellable native work")
        var active = true
        var attempts = 0
        do {
            _ = try await RemovalEviction().run(preparePolicy: {}, checkActive: {
                if !active { throw CancellationError() }
            }, readPage: { _, _ in page([.init(identifier: "1", kind: .leaf), .init(identifier: "2", kind: .leaf)]) }, evict: { _ in
                attempts += 1; active = false; return .evicted
            })
            throw RemovalTestFailure.failed("Invalidated owner returned success")
        } catch is CancellationError { }
        try check(attempts == 1, "Invalidated owner issued another native eviction")
        print("PASS cancellation and owner invalidation stop further removal requests")
    }
}
