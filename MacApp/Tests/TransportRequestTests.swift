#if MYDRIVE_DEVELOPMENT
import Foundation
import MyDriveCore

private actor RequestPages {
    var names: [String] = []
    func append(_ entries: [RemoteEntry]) { names += entries.map(\.name) }
}

private final class ByteSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int64] = []
    func append(_ bytes: Int64) { lock.withLock { samples.append(bytes) } }
    var values: [Int64] { lock.withLock { samples } }
}

/// Runs the real SMBClient + HelperOperation + Process path against a local
/// protocol fixture. No Keychain, application domain, permission or NAS access.
@main struct TransportRequestTests {
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "TransportRequestTests", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func unhex(_ value: String) throws -> Data {
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2) else { throw SMBClientError.invalidResponse }
        var result = Data()
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[offset..<(offset + 2)], as: UTF8.self), radix: 16) else {
                throw SMBClientError.invalidResponse
            }
            result.append(byte)
        }
        return result
    }

    private static func hydration(_ client: SMBClient, root: URL, paths: [String]) async throws {
        for (index, original) in paths.enumerated() {
            let path = "__route_hydrate__/" + original
            let destination = root.appendingPathComponent("hydration-\(index)-r\u{e9}sultat.txt")
            let entry = try await client.downloadForHydration(path: path, to: destination) { _ in }
            try check(try Data(contentsOf: destination) == Data(path.utf8) && entry.kind == .file,
                      "Typed hydration changed exact UTF-8 names, local destination or file metadata")
        }
        let strictPath = "__route_read__/" + paths[0]
        let strictDestination = root.appendingPathComponent("verification-read")
        _ = try await client.download(path: strictPath, to: strictDestination) { _ in }
        try check(try Data(contentsOf: strictDestination) == Data(strictPath.utf8),
                  "The strict download route stopped using the read operation")
        print("PASS hydration sends only its typed path/destination while ordinary verification keeps strict read; exact NFC/NFD bytes survive")

        for (mode, expected): (String, [Int64]) in [
            ("small", [1, 10, 20]), ("large", [1, 1 << 32, (1 << 32) + 20]), ("empty", [0])
        ] {
            let samples = ByteSamples()
            let entry = try await client.downloadForHydration(path: "__progress__/" + mode,
                to: root.appendingPathComponent("hydrate-" + mode), progress: samples.append)
            try check(samples.values == expected && entry.size == expected.last,
                      "Hydration lost monotonic, Int64 or exact empty-file completion progress")
        }
        for (mode, expected): (String, [Int64]) in [
            ("decreasing", [10]), ("negative", []), ("terminal-decreasing", [21]), ("integer-overflow", [])
        ] {
            let samples = ByteSamples()
            var rejected = false
            do {
                _ = try await client.downloadForHydration(path: "__progress__/" + mode,
                    to: root.appendingPathComponent("hydrate-" + mode), progress: samples.append)
            } catch SMBClientError.invalidResponse { rejected = true }
            try check(rejected && samples.values == expected,
                      "Invalid hydration progress reached its callback or terminal success")
        }
        for mode in ["directory", "negative", "mismatched", "missing-entry", "missing-bytes", "overflow"] {
            var rejected = false
            do {
                _ = try await client.downloadForHydration(path: "__download_terminal__/" + mode,
                    to: root.appendingPathComponent("hydrate-terminal-" + mode)) { _ in }
            } catch SMBClientError.invalidResponse { rejected = true }
            try check(rejected, "An invalid hydration terminal receipt was published")
        }
        print("PASS actual hydration subprocess progress and terminal metadata reject regressions, overflow, directory/missing/size-mismatched results")

        let samples = ByteSamples(), stream = AsyncStream<Int64>.makeStream()
        let transfer = Task {
            defer { stream.continuation.finish() }
            return try await client.downloadForHydration(path: "__progress__/cancel", to: root.appendingPathComponent("hydrate-cancel")) {
                samples.append($0); stream.continuation.yield($0)
            }
        }
        var iterator = stream.stream.makeAsyncIterator()
        try check(await iterator.next() == 1, "Hydration cancellation fixture never reported first actual bytes")
        transfer.cancel()
        var cancelled = false
        do { _ = try await transfer.value } catch is CancellationError { cancelled = true }
        try check(cancelled && samples.values == [1], "Cancelled hydration published further bytes or a terminal receipt")
        do {
            _ = try await client.downloadForHydration(path: "__unsupported__", to: root.appendingPathComponent("hydrate-unsupported")) { _ in }
            throw CocoaError(.fileReadCorruptFile)
        } catch SMBClientError.unsupportedFeature {}
        print("PASS hydration cancellation drains the actual helper and unsupported metadata remains a preserving typed error")
    }

    private static func observedListing(_ client: SMBClient) async throws {
        for mode in ["normal", "empty"] {
            let batches = ByteSamples()
            let directory = try await client.listObservedDirectory(path: "__observed__/" + mode) { held, entries in
                guard held.kind == .directory, held.objectIdentity != nil, entries.count <= 128 else {
                    throw SMBClientError.invalidResponse
                }
                batches.append(Int64(entries.count))
            }
            try check(directory.kind == .directory && batches.values == (mode == "empty" ? [] : [128,128,44]),
                      "Observed listing lost same-handle binding, page bounds or empty completion")
        }
        for mode in ["missing-start", "missing-start-empty", "page-before-start", "duplicate-start", "replaced-terminal", "canonical-terminal-name", "terminal-file", "incomplete"] {
            var refused = false
            do { _ = try await client.listObservedDirectory(path: "__observed__/" + mode) { _, _ in } }
            catch SMBClientError.invalidResponse { refused = true }
            try check(refused, "Malformed observed list was accepted: " + mode)
        }
        let first = AsyncStream<Void>.makeStream()
        let running = Task {
            defer { first.continuation.finish() }
            return try await client.listObservedDirectory(path: "__observed__/cancel") { _, _ in first.continuation.yield(()) }
        }
        var iterator = first.stream.makeAsyncIterator()
        try check(await iterator.next() != nil, "Observed cancellation never reached its real page")
        running.cancel()
        do { _ = try await running.value; throw SMBClientError.invalidResponse } catch is CancellationError {}
        print("PASS observed-list actual subprocess start ordering, same-identity terminal, empty/page bounds and cancellation")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw SMBClientError.invalidResponse }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let composed = "Caf\u{e9}/\u{c5}ngstr\u{f6}m-\u{65e5}\u{672c}\u{8a9e}.txt"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        try check(Data(composed.utf8) != Data(decomposed.utf8), "Unicode fixtures have identical wire bytes")
        let secret = "synthetic-\u{e9}\nsecond line\r\n"
        let settings = ConnectionSettings(domainID: "synthetic", displayName: "Synthetic only",
            host: "synthetic.invalid", share: "Partag\u{e9}-" + decomposed.replacingOccurrences(of: "/", with: "-"),
            username: "Utilis\u{e9}-" + decomposed)
        let client = SMBClient(settings: settings, developmentPassword: secret, helperURL: helper)

        for path in [composed, decomposed, "--replace", "folder/--password-stdin", ""] {
            let pages = RequestPages()
            try await client.list(path: path) { await pages.append($0) }
            let names = await pages.names
            try check(names.count == 1, "The local helper did not observe one complete request")
            let wire = try unhex(names[0])
            let request = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
            for (key, expected) in [("host", settings.host + ":445"), ("share", settings.share),
                                    ("username", settings.username), ("password", secret)] {
                let actual = request[key] as? String
                try check(actual.map { Data($0.utf8) } == Data(expected.utf8), "A request string changed UTF-8 bytes")
            }
            let operation = request["operation"] as! [String: String]
            try check(operation["type"] == "list" && operation["path"].map { Data($0.utf8) } == Data(path.utf8),
                      "A remote path changed UTF-8 bytes or became an option")
        }
        try check(settings.host == "synthetic.invalid", "Wire normalization changed a saved credential endpoint")
        print("PASS real subprocess preserves NFC/NFD names, share/user/secret bytes, normalizes a legacy bare endpoint and leaves saved settings unchanged")

        for (server, endpoint) in [("smb://192.0.2.10/Shared%20folder/", "192.0.2.10:445"),
                                   ("smb://_NAS_BOX_/Shared%20folder/", "_nas_box_:445")] {
            let urlSettings = ConnectionSettings(domainID: "synthetic-url", displayName: "Synthetic URL",
                host: server, share: "", username: "synthetic")
            let urlPages = RequestPages()
            try await SMBClient(settings: urlSettings, developmentPassword: secret, helperURL: helper)
                .list(path: "") { await urlPages.append($0) }
            let urlNames = await urlPages.names
            let urlWire = try JSONSerialization.jsonObject(with: unhex(urlNames[0])) as! [String: Any]
            try check(urlWire["host"] as? String == endpoint && urlWire["share"] as? String == "Shared folder" &&
                      urlSettings.host == server && urlSettings.share.isEmpty,
                      "URL trailing-slash/SMB hostname normalization changed saved settings or wire target")
        }
        let scoped = try DevelopmentConnectionScope.settings(domainID: UUID().uuidString.lowercased())
        var alias = scoped; alias.host = "smb://" + scoped.host + "/" + scoped.share + "/"
        try check(try SMBAddress(server: alias.host, share: alias.share).endpoint == scoped.host,
                  "Authorization test did not use a semantically equivalent address")
        var rawScopeRejected = false
        do { try DevelopmentConnectionScope.validate(alias) } catch { rawScopeRejected = true }
        try check(rawScopeRejected, "Address normalization broadened the exact development authorization")
        let newDraftAddress = try SMBAddress(server: alias.host, share: "")
        var newDraft = alias; newDraft.host = newDraftAddress.endpoint; newDraft.share = newDraftAddress.share
        try DevelopmentConnectionScope.validate(newDraft)
        let bareDraftAddress = try SMBAddress(server: String(scoped.host.dropLast(4)), share: scoped.share)
        newDraft.host = bareDraftAddress.endpoint; newDraft.share = bareDraftAddress.share
        try DevelopmentConnectionScope.validate(newDraft)
        for field in ["host", "share", "username", "port"] {
            var different = newDraft
            switch field {
            case "host": different.host = "192.0.2.2:445"
            case "share": different.share = "Other"
            case "username": different.username = "Other"
            default: different.host = "192.0.2.1:1445"
            }
            var refused = false
            do { try DevelopmentConnectionScope.validate(different) } catch { refused = true }
            try check(refused, "Canonical new-draft scope accepted a different endpoint/account")
        }
        print("PASS URL/default-port drafts validate their canonical authorized target; raw bound aliases and different endpoint/accounts remain refused")

        try await observedListing(client)
        try await client.probe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mydrive-transport-request-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, path) in [composed, decomposed, "--looks-like-an-option"].enumerated() {
            let destination = root.appendingPathComponent("\(index)-r\u{e9}sultat.txt")
            let observation = try await client.download(path: path, to: destination) { _ in }
            try check(try Data(contentsOf: destination) == Data(path.utf8), "Read request changed the remote or local path")
            try check(observation.size == Int64(path.utf8.count), "Read completion metadata did not match fixture content")
        }
        print("PASS typed probe/read requests, Unicode local destinations and complete response routing")
        try await hydration(client, root: root, paths: [composed, decomposed, "--looks-like-an-option"])

        for (mode, expected): (String, [Int64]) in [
            ("small", [1, 10, 20]), ("large", [1, 1 << 32, (1 << 32) + 20]), ("empty", [0])
        ] {
            let samples = ByteSamples()
            let observation = try await client.download(path: "__progress__/" + mode,
                to: root.appendingPathComponent(mode), progress: samples.append)
            try check(samples.values == expected && observation.size == expected.last,
                      "Real subprocess lost monotonic or exact terminal byte counts")
        }
        print("PASS small, large Int64 and empty downloads report exact terminal bytes without duplicate samples")

        for (mode, expected): (String, [Int64]) in [
            ("decreasing", [10]), ("negative", []), ("terminal-decreasing", [21]), ("integer-overflow", [])
        ] {
            let samples = ByteSamples()
            var rejected = false
            do {
                _ = try await client.download(path: "__progress__/" + mode,
                    to: root.appendingPathComponent(mode), progress: samples.append)
            } catch SMBClientError.invalidResponse { rejected = true }
            try check(rejected && samples.values == expected,
                      "Invalid progress reached its callback or published terminal success")
        }
        var nonReadRejected = false
        do { try await client.list(path: "__progress__/wrong-command") { _ in } }
        catch SMBClientError.invalidResponse { nonReadRejected = true }
        try check(nonReadRejected, "A non-read operation accepted byte progress")
        print("PASS decreasing, negative, overflowing and non-read progress fail before terminal success")

        let samples = ByteSamples()
        let stream = AsyncStream<Int64>.makeStream()
        let cancelled = Task {
            defer { stream.continuation.finish() }
            return try await client.download(path: "__progress__/cancel", to: root.appendingPathComponent("cancel")) {
                samples.append($0)
                stream.continuation.yield($0)
            }
        }
        var iterator = stream.stream.makeAsyncIterator()
        try check(await iterator.next() == 1, "Cancellation fixture did not report a real first sample")
        cancelled.cancel()
        var wasCancelled = false
        do { _ = try await cancelled.value }
        catch is CancellationError { wasCancelled = true }
        try check(wasCancelled && samples.values == [1], "Cancellation published more bytes or terminal completion")
        print("PASS cancellation after subprocess progress reaps the helper without terminal success")

        do {
            _ = try await client.download(path: "__unsupported__", to: root.appendingPathComponent("unsupported")) { _ in }
            throw CocoaError(.fileReadCorruptFile)
        } catch SMBClientError.unsupportedFeature {}
        print("PASS unsupported remote file features have a stable preserving error instead of transient protocol failure")

        let statName = "stat/" + decomposed
        let observed = try await client.stat(path: statName)
        try check(observed?.name.utf8.elementsEqual(statName.split(separator: "/").last!.utf8) == true,
                  "Stat changed remote UTF-8 path bytes")
        try check(try await client.stat(path: "stat/missing") == nil, "Explicit missing observation was not preserved")
        let shareRoot = try await client.stat(path: "")
        try check(shareRoot?.directory == true && shareRoot?.objectIdentity != nil && shareRoot?.name == "",
                  "The real share root cannot provide its guarded directory identity")
        do {
            _ = try await client.stat(path: "stat/missing-field")
            throw CocoaError(.fileReadCorruptFile)
        } catch SMBClientError.invalidResponse {}
        print("PASS stat distinguishes an explicit missing item from an incomplete response")

        let operationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let payload = SMBMutationRequest.Payload(source: root.appendingPathComponent("local-" + decomposed).path,
                                                 bytes: 3, sha256: String(repeating: "a", count: 64))
        let parent = SMBMutationRequest.ParentIdentity(RemoteObjectIdentity(indexNumber: 11, createdFiletime: 22))
        var prepared = SMBMutationRequest(operationID: operationID, kind: .createFile,
                                           path: "fixture/prepared", parent: parent, payload: payload)
        let upload = ByteSamples()
        let preparation = try await client.mutate(prepared, progress: upload.append)
        try check(preparation.outcome == .notApplied && preparation.code == "prepared" &&
                  preparation.receipt.staged?.cleanup_safe == false && upload.values == [3],
                  "Prepared receipt or safe default changed")
        prepared.receipt = preparation.receipt
        let committed = try await client.mutate(prepared)
        try check(committed.outcome == .committed && committed.sha256 == payload.sha256,
                  "Typed receipt did not round-trip into a verified commit")
        let reconciled = try await client.mutate(prepared, reconcile: true)
        try check(reconciled.outcome == .committed, "Reconciliation did not route its typed result")
        let moved = try await client.mutate(SMBMutationRequest(operationID: operationID, kind: .move,
            path: "fixture/source", parent: parent, destination: "fixture/moved",
            destinationParent: .init(RemoteObjectIdentity(indexNumber: 33, createdFiletime: 44)), expected: observed))
        try check(moved.entry?.name == "moved", "Move did not carry distinct frozen source/destination parent identities")
        print("PASS typed mutation receipts, real upload samples, conservative cleanup default and reconciliation")

        var allocatedRequest = SMBMutationRequest(operationID: operationID, kind: .createFile,
            path: "fixture/allocated", parent: parent, payload: payload)
        let allocatedBytes = ByteSamples()
        let allocation = try await client.mutate(allocatedRequest, progress: allocatedBytes.append)
        try check(allocation.code == "allocated" && allocation.receipt.staged?.phase == .allocated &&
                  allocation.receipt.staged?.security_sha256 == String(repeating: "b", count: 64) && allocatedBytes.values.isEmpty,
                  "Allocation receipt was absent, unqualified or reported bytes before acknowledgement")
        allocatedRequest.receipt = allocation.receipt
        let preparedAllocation = try await client.mutate(allocatedRequest, progress: allocatedBytes.append)
        try check(preparedAllocation.code == "prepared" && preparedAllocation.receipt.staged?.phase == .prepared && allocatedBytes.values == [3],
                  "Acknowledged allocation did not transition through verified preparation")
        allocatedRequest.receipt = preparedAllocation.receipt
        let publishedAllocation = try await client.mutate(allocatedRequest, progress: allocatedBytes.append)
        try check(publishedAllocation.outcome == .committed && allocatedBytes.values == [3], "Prepared publication repeated upload progress")
        print("PASS actual subprocess allocation precedes every byte and a qualified receipt round-trips through preparation and publication")

        for mode in ["wrong-id", "wrong-hash", "wrong-name", "wrong-size", "bad-outcome", "missing-cleanup", "wrong-artifact",
                     "negative", "regressing", "excessive", "allocated-missing-security", "allocated-bad-phase",
                     "allocated-directory", "allocated-nonempty", "allocated-unsafe"] {
            do {
                _ = try await client.mutate(SMBMutationRequest(operationID: operationID, kind: .createFile,
                                                               path: "fixture/" + mode, parent: parent, payload: payload))
                throw CocoaError(.fileReadCorruptFile)
            } catch SMBClientError.invalidResponse {}
        }
        print("PASS malformed mutation identity, bytes, hash, receipts and progress cannot report success")

        for request in [
            SMBMutationRequest(operationID: operationID, kind: .createDirectory, path: "fixture/invalid",
                parent: .init(RemoteObjectIdentity(indexNumber: 0, createdFiletime: 22))),
            SMBMutationRequest(operationID: operationID, kind: .move, path: "fixture/source", parent: parent,
                destination: "fixture/moved", expected: observed),
            SMBMutationRequest(operationID: operationID, kind: .delete, path: "fixture/source", parent: parent,
                destinationParent: parent, expected: observed)
        ] {
            do { _ = try await client.mutate(request); throw CocoaError(.fileReadCorruptFile) }
            catch SMBClientError.invalidResponse {}
        }
        try check(observed?.observation.objectIdentity == RemoteObjectIdentity(indexNumber: 1, createdFiletime: 1),
                  "Typed SMB identity was not attached to a listing/stat observation")
        print("PASS parent identities are required, nonzero, move-scoped and preserved by the actual subprocess wire")

        for mode in ["missing", "file", "zero", "reparse"] {
            do {
                try await client.list(path: "__listing__/" + mode) { _ in }
                throw CocoaError(.fileReadCorruptFile)
            } catch SMBClientError.invalidResponse {}
        }
        print("PASS directory listings require a terminal ordinary-directory identity before reporting complete")

        try await scopedWire(client, parent: parent, operationID: operationID)
        try await treeScopedWire(client, parent: parent, operationID: operationID, directory: root)
        let unknown = try await client.mutate(SMBMutationRequest(operationID: operationID, kind: .createFile,
            path: "fixture/allocation-unknown-archive", parent: parent, payload: payload))
        try check(unknown.outcome == .uncertain && unknown.code == "allocation_unknown" && unknown.receipt.archived?.cleanup_safe == false,
                  "An unknown allocation discarded newly reported preserved archive evidence")
        print("PASS unknown allocation preserves conservative archive evidence instead of dropping it during decoding")

        let largestPassword = String(repeating: "\u{e9}", count: 2048)
        try await SMBClient(settings: settings, developmentPassword: largestPassword, helperURL: helper).probe()
        for password in ["", largestPassword + "\u{e9}"] {
            do {
                try await SMBClient(settings: settings, developmentPassword: password, helperURL: helper).probe()
                throw SMBClientError.invalidResponse
            } catch SMBClientError.authenticationRequired { }
        }
        do {
            try await client.list(path: String(repeating: "x", count: 65_536)) { _ in }
            throw SMBClientError.invalidResponse
        } catch HelperOperationError.oversizedInput { }
        print("PASS UTF-8 password limit and bounded complete request fail before launch")
    }

    private static func scopedWire(_ client: SMBClient, parent: SMBMutationRequest.ParentIdentity, operationID: UUID) async throws {
        let root = "fixture/Caf\u{e9}"
        let encoded = try JSONSerialization.data(withJSONObject: ["root_path": root,
            "root": ["index_number": 11, "created_filetime": 22], "parent": ["index_number": 55, "created_filetime": 66]])
        let scope = try JSONDecoder().decode(SMBDeleteScope.self, from: encoded)
        let page = RequestPages()
        _ = try await client.listDirectory(path: root, deleteScope: scope) { await page.append($0) }
        let wire = try unhex(await page.names[0])
        let request = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
        let operation = request["operation"] as! [String: Any], captured = operation["delete_scope"] as! [String: Any]
        try check((captured["root_path"] as? String).map { Data($0.utf8) } == Data(root.utf8),
                  "Scoped list changed frozen root UTF-8 bytes")
        try check(try await client.stat(path: root + "/missing", deleteScope: scope) == nil,
                  "Scoped stat could not preserve explicit desired absence")
        let target = SMBEntry(name: "delete", bytes: 3, directory: false, index_number: 1,
            created_filetime: 1, modified_filetime: 0, changed_filetime: 0, attributes: 0)
        let result = try await client.mutate(SMBMutationRequest(operationID: operationID, kind: .delete,
            path: root + "/delete", parent: parent, expected: target, deleteScope: scope))
        try check(result.outcome == .committed, "Scoped mutation did not preserve its typed request")
        do { _ = try await client.stat(path: root + "/scope-changed", deleteScope: scope); throw CocoaError(.fileReadCorruptFile) }
        catch SMBClientError.scopeChanged {}
        do { _ = try await client.stat(path: "outside/file", deleteScope: scope); throw CocoaError(.fileReadCorruptFile) }
        catch SMBClientError.invalidResponse {}
        print("PASS actual subprocess list/stat/delete preserve frozen selection fences, exact Unicode root bytes and explicit scope refusal")
    }

    private static func treeScopedWire(_ client: SMBClient, parent: SMBMutationRequest.ParentIdentity,
                                       operationID: UUID, directory: URL) async throws {
        let scope = SMBTreeScope(arena_path: "fixture/Caf\u{e9}/.mydrive-" + operationID.uuidString.lowercased() + ".tree",
            arena: parent, parent: .init(.init(indexNumber: 55, createdFiletime: 66)))
        for version: Int? in [nil, 1, 3] {
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as! [String: Any]
            legacy["layout_version"] = version
            do { _ = try JSONDecoder().decode(SMBTreeScope.self, from: JSONSerialization.data(withJSONObject: legacy)); throw CocoaError(.fileReadCorruptFile) }
            catch is DecodingError {}
        }
        print("PASS private scopes require explicit layout2; missing or unsupported authority fails before RPC")
        let payload = scope.arena_path, pages = RequestPages()
        _ = try await client.listDirectory(path: payload, treeScope: scope) { await pages.append($0) }
        let wire = try unhex(await pages.names[0]), request = try JSONSerialization.jsonObject(with: wire) as! [String: Any]
        let operation = request["operation"] as! [String: Any], captured = operation["tree_scope"] as! [String: Any]
        try check(captured["layout_version"] as? Int == 2 && Set(captured.keys) == Set(["layout_version", "arena_path", "arena", "parent"]) &&
            (captured["arena_path"] as? String).map { Data($0.utf8) } == Data(scope.arena_path.utf8),
                  "Private arena UTF-8 bytes changed in the actual subprocess request")
        let path = payload + "/Cafe\u{301}.txt", destination = directory.appendingPathComponent("tree-read")
        _ = try await client.download(path: path, to: destination, treeScope: scope) { _ in }
        try check(try Data(contentsOf: destination) == Data(path.utf8), "Scoped private read changed its payload path")
        try check(try await client.stat(path: payload + "/missing", treeScope: scope) == nil,
                  "Private scoped stat lost explicit absence")
        _ = try await client.mutate(.init(operationID: operationID, kind: .createFile,
            path: scope.arena_path + "/.mydrive-" + operationID.uuidString.lowercased() + ".node", parent: parent,
            payload: .init(source: destination.path, bytes: 3, sha256: String(repeating: "a", count: 64)), treeScope: scope))
        do { _ = try await client.stat(path: payload + "/tree-scope-changed", treeScope: scope); throw CocoaError(.fileReadCorruptFile) }
        catch SMBClientError.scopeChanged {}
        do { _ = try await client.download(path: "outside/scratch", to: directory.appendingPathComponent("forbidden"), treeScope: scope) { _ in }; throw CocoaError(.fileReadCorruptFile) }
        catch SMBClientError.invalidResponse {}
        print("PASS real subprocess preserves private arena fences for list/stat/read/create and refuses unscoped sibling reads")
    }
}
#endif
