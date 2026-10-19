import Darwin
import Foundation

private struct FeatureFailure: Error { let message: String }
private actor ActiveTransfers {
    private var count = 0
    private(set) var maximum = 0
    func enter() { count += 1; maximum = max(maximum, count) }
    func leave() { count -= 1 }
}

@main struct UIFunctionalityTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw FeatureFailure(message: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw FeatureFailure(message: "Invalid input was accepted")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PreferencesStore(url: root.appendingPathComponent("preferences.json"))
        var preferences = try store.load()
        preferences.downloadLimited = true; preferences.downloadMBps = 12.5
        preferences.excludedPatterns = ["*.tmp", "node_modules", "Private/*"]
        try store.save(preferences)
        try check(try store.load() == preferences, "Preferences did not survive a restart")
        try check(preferences.excludes("a/file.tmp") && preferences.excludes("a/node_modules/code.js") &&
            preferences.excludes("Private/nested/file") && !preferences.excludes("a/file.txt"), "Exclusions did not respect whole names and path scope")
        preferences.maximumCacheGB = .nan
        try rejects { try store.save(preferences) }
        try check(try store.load().maximumCacheGB == 20, "Rejected settings changed saved policy")
        var oversized = UserPreferences()
        oversized.excludedPatterns = Array(repeating: String(repeating: "\u{1}", count: 256), count: 100)
        try rejects { try store.save(oversized) }
        try check(try store.load().excludedPatterns == preferences.excludedPatterns, "Oversized preferences replaced their readable predecessor")
        try Data("{\"showDock\":false}".utf8).write(to: store.url)
        try check(try !store.load().showDock && store.load().showMenuBar, "Older preferences did not receive safe defaults")
        print("PASS persistent validated preferences, migration defaults and scoped exclusion globs")
        let globs = ExclusionMatcher(patterns: ["*.tmp", "a[1].txt", "Private/*", "cache", "?👩‍💻.bin"])
        try check(globs.excludes("a/line\nbreak.tmp") && globs.excludes("a[1].txt") && !globs.excludes("a1.txt") &&
            globs.excludes("Private/nested/file") && globs.excludes("folder/cache/file") && globs.excludes("x👩‍💻.bin"),
            "Exclusion wildcards mishandled literal punctuation, Unicode or folder scope")
        let repeatedStars = ExclusionMatcher(patterns: [String(repeating: "*a", count: 100) + "z"])
        try check(!repeatedStars.excludes(String(repeating: "a", count: 1000)), "Repeated wildcard suffix matched an absent final character")
        print("PASS compiled wildcard policies handle Unicode and adversarial patterns without regex backtracking")

        let settings = ConnectionSettings(domainID: UUID().uuidString.lowercased(), displayName: "Example",
            host: "nas.example:445", share: "Shared", username: "account")
        let bytes = try JSONEncoder().encode(ConnectionProfiles(settings: [settings]))
        let imported = try ConnectionProfiles.decode(bytes)
        try check(imported.count == 1 && imported[0].id != settings.id && imported[0].hasSameEndpoint(as: settings),
            "Imported profiles reused local identities or changed endpoints")
        let json = String(decoding: bytes, as: UTF8.self)
        try check(!json.contains("password") && !json.contains(settings.id), "Portable profile leaked credentials or local identity")
        try rejects { _ = try ConnectionProfiles.decode(Data(json.replacingOccurrences(of: "\"version\":1", with: "\"version\":99").utf8)) }
        print("PASS portable profiles preserve endpoints and generate fresh identities without passwords")

        var options = MountOptions()
        options.overrideBandwidth = true; options.downloadLimited = true; options.downloadMBps = 4.5
        options.excludedPatterns = ["*.tmp"]; options.pauseReason = .user
        let profileBytes = try JSONEncoder().encode(ConnectionProfiles(settings: [settings], options: [settings.id: options]))
        let profiles = try ConnectionProfiles.read(profileBytes)
        var expectedOptions = options; expectedOptions.pauseReason = nil
        try check(profiles.first?.options == expectedOptions, "Profile lost mount options or exported a paused state")
        let connections = ConnectionStore(root: root.appendingPathComponent("Connections"))
        var oversizedOptions = options; oversizedOptions.excludedPatterns = oversized.excludedPatterns
        try rejects { try connections.importProfile(ConnectionProfiles.Imported(settings: settings, options: oversizedOptions)) }
        try check(!FileManager.default.fileExists(atPath: connections.folder(for: settings.id).path),
            "Oversized mount options left a partly imported Connection")
        try connections.importProfile(profiles[0])
        try check(try connections.settings(for: profiles[0].settings.id) == profiles[0].settings &&
            MountOptions.load(in: connections.folder(for: profiles[0].settings.id)) == expectedOptions,
            "Profile and mount options were not published together")
        try rejects { try connections.importProfile(profiles[0]) }
        try check(try connections.settings(for: profiles[0].settings.id) == profiles[0].settings, "Import replaced an existing Connection")
        try check(try connections.removeUnregisteredSettings(profiles[0].settings) == nil,
            "Removing an imported, never-connected profile retained only its options")
        print("PASS profile options round trip together and cannot replace an existing Connection")

        try await concurrency()
        try transferSnapshots(root)
        try boundedObservations(root)

        let target = root.appendingPathComponent("data")
        try Data(repeating: 0, count: 1024).write(to: target)
        try rejects { _ = try BoundedFile.read(target, maximumBytes: 64) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try rejects { _ = try BoundedFile.read(link, maximumBytes: 2048) }
        let fifo = root.appendingPathComponent("fifo")
        try check(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture failed")
        try rejects { _ = try BoundedFile.read(fifo, maximumBytes: 2048) }
        print("PASS imports and preferences reject oversized, symlink and FIFO inputs without blocking")
    }

    private static func concurrency() async throws {
        let gate = TransferConcurrency(), counts = ActiveTransfers()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.perform(limit: 2) {
                        await counts.enter()
                        try await Task.sleep(for: .milliseconds(2))
                        await counts.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        try check(await counts.maximum == 2, "The active transfer limit was ignored")
        let first = try await gate.acquire(limit: 1)
        let queued = Task { try await gate.acquire(limit: 1) }
        for _ in 0..<10_000 { if await gate.pendingCount == 1 { break }; await Task.yield() }
        try check(await gate.pendingCount == 1, "A full transfer gate did not queue work")
        queued.cancel()
        do { _ = try await queued.value; throw FeatureFailure(message: "Cancelled queued transfer acquired a permit") }
        catch is CancellationError {}
        await gate.release(first)
        do { try await gate.perform(limit: 1) { throw FeatureFailure(message: "Fixture failure") } }
        catch is FeatureFailure {}
        let last = try await gate.acquire(limit: 1)
        await gate.release(last)
        print("PASS active file transfers obey the cap; queued cancellation and failed work release permits")
    }

    private static func transferSnapshots(_ root: URL) throws {
        let url = root.appendingPathComponent("activity.json"), progress = Progress(totalUnitCount: 1)
        let ledger = TransferLedger(url: url)
        let empty = ledger.begin(itemID: "empty", name: "Empty.txt", direction: .downloading, progress: progress, expectedBytes: 0)
        try check(ledger.snapshot().first?.total == 0 && ledger.snapshot().first?.fraction == nil,
            "Preparing an empty file guessed a byte count or claimed completion")
        progress.completedUnitCount = 1
        ledger.finish(empty, bytes: 0)
        let failed = ledger.begin(itemID: "first-template", name: "File.txt", direction: .uploading, progress: progress)
        ledger.prepared(failed, itemID: "file", path: "Folder/File.txt", bytes: 42)
        try check(ledger.snapshot().last?.itemID == "file" && ledger.snapshot().last?.total == 42 &&
            TransferLedger(url: url).snapshot().last?.path == "Folder/File.txt",
            "Prepared upload identity and length were not visible and durable before completion")
        ledger.finish(failed, error: CocoaError(.fileWriteUnknown))
        let retry = ledger.begin(itemID: "retry-template", name: "File.txt", direction: .uploading, progress: progress)
        ledger.prepared(retry, itemID: "file", path: "Folder/File.txt", bytes: 42)
        ledger.finish(retry, bytes: 42)
        let conflict = ledger.begin(itemID: "conflict", name: "Conflict.txt", direction: .uploading, progress: progress)
        ledger.finish(conflict, conflict: true, bytes: 10)
        ledger.resolve(conflict)
        let entries = TransferLedger(url: url).snapshot()
        try check(entries.first?.total == 0 && entries.first?.completed == 0 && entries.first?.fraction == 1,
            "A completed empty file was displayed as one byte or still in progress")
        try check(entries.first(where: { $0.id == failed })?.resolved == true && entries.first(where: { $0.id == retry })?.total == 42,
                  "Successful retry did not resolve prior failure or save the verified byte count")
        try check(entries.first(where: { $0.id == conflict })?.resolved == true, "Reviewed conflict was not acknowledged durably")
        for entry in entries { _ = try entry.validated() }
        var invalid = entries[0]; invalid.bytesPerSecond = .infinity
        try rejects { _ = try invalid.validated() }
        var cache = CacheUsage(cached: .max, keptOffline: .max)
        try check(cache.total == .max, "Aggregate cache sizes overflowed")
        cache.cached = -1
        try rejects { _ = try cache.validated() }
        print("PASS persistent transfer history uses real byte counts and rejects corrupt observations")
    }

    private static func boundedObservations(_ root: URL) throws {
        // Control characters exercise JSON's worst-case six-byte escaping.
        let path = String(repeating: "\u{1}", count: 32768)
        let records = (0..<40).map { index in
            TransferEntry(id: UUID(), itemID: "item-\(index)", name: "File.txt", direction: .uploading,
                state: .completed, started: Date(timeIntervalSinceReferenceDate: Double(index)),
                completed: 1, total: 1, bytesPerSecond: 0, message: "Finished", path: path)
        }
        let data = try ProviderSnapshot(cache: CacheUsage(), transfers: records, connection: "online").encodedForControl()
        let snapshot = try JSONDecoder().decode(ProviderSnapshot.self, from: data).validated()
        try check(data.count <= 2_097_152 && !snapshot.transfers.isEmpty && snapshot.transfers.count < records.count &&
            snapshot.transfers.last == records.last, "Long paths exceeded the control bound or lost the latest complete observation")

        let url = root.appendingPathComponent("large-activity.json"), ledger = TransferLedger(url: url)
        var newest: UUID?
        for index in 0..<12 {
            let id = ledger.begin(itemID: "large-\(index)", name: "File.txt", direction: .uploading,
                progress: Progress(totalUnitCount: 1), path: path)
            ledger.finish(id, bytes: 1); newest = id
        }
        let saved = try BoundedFile.read(url, maximumBytes: 1_048_576)
        let restored = TransferLedger(url: url).snapshot()
        try check(!saved.isEmpty && !restored.isEmpty && restored.last?.id == newest && restored.last?.path == path,
            "Oversized history could not reopen its latest whole records")

        var cursor: String?, visited: [String] = []
        let library = (0..<30).map { LibraryEntry(id: String($0), name: "File.txt", path: path,
            folder: false, size: 1, keptOffline: false, downloaded: false) }
        var remaining = library
        repeat {
            let bytes = try LibraryPage(entries: remaining, nextID: nil, generation: 1).encodedForControl()
            let page = try JSONDecoder().decode(LibraryPage.self, from: bytes).validated()
            try check(bytes.count <= 2_097_152 && !page.entries.isEmpty, "Library long-path page exceeded its bound or stopped making progress")
            visited += page.entries.map(\.id); cursor = page.nextID
            remaining.removeFirst(page.entries.count)
            try check(cursor == (remaining.isEmpty ? nil : visited.last), "Trimmed library cursor skipped unseen entries")
        } while cursor != nil
        try check(visited == library.map(\.id), "Bounded library pages skipped or duplicated an entry")
        print("PASS escaped long paths retain bounded whole history and page every library entry without gaps")
    }
}
