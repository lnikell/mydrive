import Foundation
import FileProvider
import MyDriveCore
import Darwin
import UniformTypeIdentifiers

private struct TestFailure: Error { let message: String }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}

private final class FakeEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    enum Behavior: Sendable { case backgroundDuplicateCompletion, never }
    let behavior: Behavior
    let item: ProviderItem
    private let lock = NSLock()
    private var observer: ProviderCallback<any NSFileProviderEnumerationObserver>?

    init(_ behavior: Behavior, item: ProviderItem) {
        self.behavior = behavior
        self.item = item
    }

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observer != nil
    }

    func invalidate() {}

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let callback = ProviderCallback(observer)
        lock.lock()
        self.observer = callback
        lock.unlock()
        if behavior == .backgroundDuplicateCompletion {
            DispatchQueue.global().async { @Sendable [item] in
                callback.value.didEnumerate([item])
                callback.value.finishEnumerating(upTo: nil)
                callback.value.finishEnumeratingWithError(CocoaError(.fileReadUnknown))
                callback.value.didEnumerate([item])
            }
        }
    }

    func finishLate() {
        lock.lock()
        let callback = observer
        lock.unlock()
        callback?.value.finishEnumerating(upTo: nil)
    }
}

@main
private struct AdapterTests {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--hold-lease" {
            let lease = try DomainOwnerLease(at: URL(fileURLWithPath: CommandLine.arguments[2]))
            defer { lease.release() }
            FileHandle.standardOutput.write(Data("LOCKED\n".utf8))
            try await Task.sleep(for: .seconds(30))
            return
        }
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--unavailable-package-types" {
            try await MutationRepresentationTests.unavailableRegistry()
            return
        }
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--tree-intake-only" {
            let checks = try await LocalTreeSnapshotTests.run()
            print("PASS \(checks) local tree snapshot groups")
            return
        }
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--tree-import-only" {
            let checks = try await TreeImportTests.run() + TreeLayoutTests.run() + TreeFrontierTests.run() + TreeWorkProgressTests.run()
            print("PASS \(checks) tree import groups")
            return
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let catalog = try Catalog(databaseURL: temporary.appendingPathComponent("catalog.sqlite"))
        let scan = try await catalog.beginScan()
        try await catalog.stage([RemoteEntry(
            name: "Example.txt", kind: .file, contentVersion: "revision-1", metadataVersion: "metadata-1", size: 12)], in: scan)
        try await catalog.completeScan(scan)
        let models = try await catalog.children()
        guard let model = models.items.first,
              let root = try await catalog.item(id: Catalog.rootID) else {
            throw TestFailure(message: "Fixture missing")
        }
        let item = ProviderItem(model, policy: .onDemand, displayName: "Test NAS")
        let rootItem = ProviderItem(root, policy: .keepAvailable, displayName: "Test NAS")
        try require(item.itemIdentifier.rawValue == model.id, "Stable catalog identity changed")
        try require(item.capabilities.contains(.allowsWriting), "Regular NAS files do not advertise implemented writes")
        try require(item.fileSystemFlags.contains(.userWritable), "Regular NAS files do not have writable local permissions")
        try require(rootItem.filename == "Test NAS" && rootItem.itemIdentifier == .rootContainer, "Root metadata is invalid")
        try require(rootItem.contentPolicy == .downloadEagerlyAndKeepDownloaded, "Root offline policy was lost")
        print("PASS immutable provider metadata and root offline policy")

        let directoryScan = try await catalog.beginScan()
        try await catalog.stage([
            RemoteEntry(name: "Document.rtfd", kind: .directory, contentVersion: "package", metadataVersion: "package"),
            RemoteEntry(name: "Folder.txt", kind: .directory, contentVersion: "folder", metadataVersion: "folder")
        ], in: directoryScan)
        try await catalog.completeScan(directoryScan)
        guard let package = try await catalog.child(named: "Document.rtfd", in: Catalog.rootID),
              let folder = try await catalog.child(named: "Folder.txt", in: Catalog.rootID) else {
            throw TestFailure(message: "Package fixtures missing")
        }
        for directory in [package, folder] {
            let native: any NSFileProviderItem = ProviderItem(directory, policy: .onDemand, displayName: "Test NAS")
            try require(native.contentType == .folder,
                        "NAS directory must expose the File Provider folder contract: \(directory.entry.name)")
        }
        print("PASS native directory contract for package and regular extensions")

        let locked = ProviderErrors.translate(CredentialStoreError.loginKeychainLocked) as NSError
        let unavailable = ProviderErrors.translate(SMBClientError.serverUnreachable) as NSError
        try require(locked.domain == NSFileProviderErrorDomain && locked.code == NSFileProviderError.notAuthenticated.rawValue,
                    "Locked Keychain was reported as a generic transient error")
        try require(unavailable.domain == NSFileProviderErrorDomain && unavailable.code == NSFileProviderError.serverUnreachable.rawValue,
                    "Unavailable NAS lost its connection error classification")
        print("PASS locked Keychain and NAS connection error translation")

        let clock = ContinuousClock()
        var retry = RefreshRetryDelay(interval: .milliseconds(60))
        retry.failed()
        let beforeRetry = clock.now
        try await retry.wait()
        try require(beforeRetry.duration(to: clock.now) >= .milliseconds(40), "Connection retry did not wait")
        var longRetry = RefreshRetryDelay(interval: .seconds(10))
        longRetry.failed()
        longRetry.succeeded()
        let resetRetry = longRetry
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await resetRetry.wait() }
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw TestFailure(message: "Successful refresh retained the retry delay")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        longRetry.failed()
        let pendingRetry = longRetry
        let sleeping = Task { try await pendingRetry.wait() }
        try await Task.sleep(for: .milliseconds(10))
        let beforeCancellation = clock.now
        sleeping.cancel()
        do { try await sleeping.value; throw TestFailure(message: "Cancelled retry completed successfully") }
        catch is CancellationError {}
        try require(beforeCancellation.duration(to: clock.now) < .seconds(1), "Retry cancellation waited for its deadline")
        print("PASS monotonic retry delay, success reset, and prompt cancellation")

        let initial = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
        let duplicate = FakeEnumerator(.backgroundDuplicateCompletion, item: item)
        let page = try await MaterializedPage.read(from: duplicate, startingAt: initial, timeout: .seconds(1))
        try require(page.identifiers == [model.id] && page.next == nil, "Background enumeration produced wrong page")
        print("PASS background Objective-C callbacks and duplicate completion")

        let hanging = FakeEnumerator(.never, item: item)
        let cancelled = Task { @MainActor in
            try await MaterializedPage.read(from: hanging, startingAt: initial, timeout: .seconds(2))
        }
        while !hanging.started { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw TestFailure(message: "Cancellation returned a successful page") }
        catch is CancellationError {}
        hanging.finishLate()
        print("PASS cancellation resumes a hanging page and ignores late completion")

        let early = FakeEnumerator(.never, item: item)
        let alreadyCancelled = Task { @MainActor in
            try await MaterializedPage.read(from: early, startingAt: initial, timeout: .seconds(2))
        }
        alreadyCancelled.cancel()
        do { _ = try await alreadyCancelled.value; throw TestFailure(message: "Pre-cancelled enumeration succeeded") }
        catch is CancellationError {}
        print("PASS cancellation before continuation installation")

        let silent = FakeEnumerator(.never, item: item)
        do {
            _ = try await MaterializedPage.read(from: silent, startingAt: initial, timeout: .milliseconds(20))
            throw TestFailure(message: "Missing framework callback never timed out")
        } catch let error as CocoaError {
            try require(error.code == .fileReadUnknown, "Unexpected timeout error")
        }
        print("PASS bounded wait when macOS supplies no completion")

        let registry = ProviderTasks()
        let cancelledWork: Bool = await withCheckedContinuation { continuation in
            let progress = registry.run { _ in
                do { try await Task.sleep(for: .seconds(10)); continuation.resume(returning: false) }
                catch { continuation.resume(returning: Task.isCancelled) }
            }
            DispatchQueue.global().async { @Sendable in progress.cancel() }
        }
        try require(cancelledWork, "Progress cancellation did not reach the task")
        let pending = registry.invalidate()
        for task in pending { await task.value }
        let invalidatedWork: Bool = await withCheckedContinuation { continuation in
            _ = registry.run { _ in continuation.resume(returning: Task.isCancelled) }
        }
        try require(invalidatedWork, "Invalidated task registry started uncancelled work")
        print("PASS progress cancellation and invalidated task ownership")

        let leaseURL = temporary.appendingPathComponent("domain.owner")
        let first = try DomainOwnerLease(at: leaseURL)
        do {
            _ = try DomainOwnerLease(at: leaseURL)
            throw TestFailure(message: "Two extension owners acquired one domain")
        } catch let error as CocoaError {
            try require(error.code == .fileLocking, "Unexpected contention error")
        }
        first.release()
        let replacement = try DomainOwnerLease(at: leaseURL)
        replacement.release()
        print("PASS owner exclusion and explicit takeover")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hold-lease", leaseURL.path]
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        defer { if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        var ready = false
        for try await line in output.fileHandleForReading.bytes.lines {
            ready = line == "LOCKED"
            break
        }
        try require(ready, "Child owner did not acquire its lease")
        Darwin.kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let afterCrash = try DomainOwnerLease(at: leaseURL)
        afterCrash.release()
        print("PASS kernel releases owner lease after process death")
        var checkCount = 10
        checkCount += try ContentFetchProgressTests.run()
        checkCount += try CatalogChangeTests.run()
        checkCount += try await CatalogRefreshTests.run()
        checkCount += try await DomainVersionTests.run()
        checkCount += try await DomainOperationGateTests.run()
        checkCount += try await MutationTests.run()
        checkCount += try await MutationRecoveryTests.run()
        checkCount += try await MutationRepresentationTests.run()
        checkCount += try await LocalTreeSnapshotTests.run()
        checkCount += try await TreeImportTests.run()
        checkCount += try await TreeLayoutTests.run()
        checkCount += try await TreeFrontierTests.run()
        checkCount += try TreeWorkProgressTests.run()
        checkCount += try await RecursiveDeleteTests.run()
        checkCount += try await ProviderActionTests.run()
        checkCount += try await PolicyAwareEvictionTests.run()
        #if MYDRIVE_DEVELOPMENT
        checkCount += try DevelopmentPayloadShapeTests.run()
        checkCount += try await DevelopmentCredentialTests.run()
        #endif
        print("\(checkCount) provider adapter checks passed; no NAS or registered File Provider was used.")
    }
}
