import FileProvider
import Foundation
import MyDriveCore

enum TreeLayoutTests {
    static func run() async throws -> Int {
        try requiredLayout()
        try await correctCreationParents()
        try await missingOrUnsafeProof()
        try await localRetirementRestart()
        return 4
    }

    private static func requiredLayout() throws {
        let parent = SMBMutationRequest.ParentIdentity(.init(indexNumber: 1, createdFiletime: 2))
        let scope = SMBTreeScope(arena_path: "Caf\u{e9}/stage", arena: parent, parent: parent)
        let other = SMBTreeScope(arena_path: "Cafe\u{301}/stage", arena: parent, parent: parent)
        try mutationCheck(scope != other, "Layout fences canonically equated different UTF-8 paths")
        let reference = StagedTreeReference(id: UUID(), nodeCount: 1, totalBytes: 0, sha256: String(repeating: "a", count: 64))
        let state = TreeImportLocalState(tree: reference)
        for version: Int? in [nil, 1, 3] {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
            json["layoutVersion"] = version
            do {
                _ = try JSONDecoder().decode(TreeImportLocalState.self, from: JSONSerialization.data(withJSONObject: json))
                throw MutationTestFailure(message: "Missing/legacy local tree authority was accepted")
            } catch is DecodingError {}
        }
        let progress = Progress(totalUnitCount: 1)
        _ = try TreeWorkProgress.configure(progress, tree: reference)
        try mutationCheck(progress.totalUnitCount == 3_000_001, "Root creation/place elimination left false progress milestones")
        print("PASS layout2 is explicit, old records fail closed, UTF-8 fences stay exact and root progress has three milestones")
    }

    private static func correctCreationParents() async throws {
        let f = try await TreeImportTests.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let root = try await f.owner.write(f.input, create: true, progress: Progress(totalUnitCount: 1))
        let requests = await f.peer.mutationRequests
        let scoped = requests.filter { $0.tree_scope != nil }
        let arenaCreates = requests.filter { $0.tree_scope == nil && $0.kind == .createDirectory }
        let publishes = scoped.filter { $0.kind == .move && $0.path == $0.tree_scope!.arena_path }
        try mutationCheck(publishes.count == 1 && arenaCreates.count >= 1 &&
            Set(arenaCreates.map(\.path)).count == 1, "Importer created an extra payload-root ACL layer")
        let publish = publishes[0], scope = publish.tree_scope!
        try mutationCheck(publish.parent == scope.parent && publish.destination_parent == scope.parent &&
            parent(publish.path).utf8.elementsEqual(parent(publish.destination!).utf8), "Root publication was not a same-parent exclusive rename")
        for request in scoped where request.kind == .move && request.path != scope.arena_path {
            try mutationCheck(parent(request.path).utf8.elementsEqual(parent(request.destination!).utf8) &&
                request.parent == request.destination_parent, "Child placement changed inheritance depth")
        }
        let createParents = Set(scoped.filter { $0.kind == .createFile || $0.kind == .createDirectory }.map { parent($0.path) })
        try mutationCheck(createParents.count >= 2 && !createParents.contains(scope.arena_path + "/payload"),
                          "Nested objects were created in a centralized scratch directory")
        let calls = await f.peer.counts().2
        var late = MutationPlan(key: UUID(), itemID: root.id, parentID: root.parentID!, filename: root.entry.name,
                                steps: [], preservedOriginal: nil)
        // An unrelated plan has no authority; post-publication cleanup never
        // turns the published root into a disposable staging directory.
        await ProviderTreeImport(mutations: f.owner).cleanPublished(&late)
        let finalCalls = await f.peer.counts().2
        let remoteRoot = await f.peer.stat(root.entry.name)
        try mutationCheck(calls == finalCalls && remoteRoot != nil,
                          "Post-publication cleanup issued a remote root deletion")
        print("PASS staged root is the future payload; every child is born/placed in its final logical parent and published root is never cleaned remotely")
    }

    private static func missingOrUnsafeProof() async throws {
        for unsafe in [false, true] {
            let f = try await TreeImportTests.fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            await f.peer.setTreeReadCorrupt(true)
            do { _ = try await f.owner.write(f.input, create: true, progress: Progress(totalUnitCount: 1)) } catch {}
            let rootID = try await f.owner.catalog.providerID(forCreateTemplate: f.input.id)
            let head = try await f.owner.catalog.treeImportStatus(rootID: rootID)!
            let history = try await f.owner.catalog.treeImportOperations(key: head.key)
            let child = history.first { $0.step == .create && $0.operation.intent.payload != nil }!
            let key = child.operation.intent.idempotencyKey
            if unsafe {
                var plan = try f.owner.staging.load(key)!
                let request = plan.steps[0].request, entry = plan.steps[0].result!.entry!
                plan.steps[0].request.receipt.staged = .init(path: request.sidecar("stage"), entry: entry, cleanup_safe: false)
                try f.owner.staging.save(plan)
            } else { try f.owner.staging.removePlan(key) }
            await f.peer.setTreeReadCorrupt(false)
            let calls = await f.peer.counts().2
            do {
                _ = try await f.owner.write(TreeImportTests.request(contents: nil), create: true, progress: Progress(totalUnitCount: 1))
                throw MutationTestFailure(message: "Missing or unsafe artifact proof allowed tree publication")
            } catch is MutationTestFailure { throw MutationTestFailure(message: "Missing or unsafe artifact proof allowed tree publication") }
            catch {}
            let finalCalls = await f.peer.counts().2, live = try await f.owner.catalog.children().items
            try mutationCheck(calls == finalCalls && live.isEmpty &&
                (try LocalTreeSnapshot.load(head.tree, in: f.owner.staging).entries()).count == 5,
                "Prepublication refusal wrote to NAS or discarded complete input")
        }
        print("PASS missing child plans and unsafe artifact receipts block before any verification/publication RPC")
    }

    private static func localRetirementRestart() async throws {
        let f = try await TreeImportTests.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.peer.setTreeReadCorrupt(true)
        do { _ = try await f.owner.write(f.input, create: true, progress: Progress(totalUnitCount: 1)) } catch {}
        let rootID = try await f.owner.catalog.providerID(forCreateTemplate: f.input.id)
        let head = try await f.owner.catalog.treeImportStatus(rootID: rootID)!
        var recovery = try f.owner.staging.load(head.key)!
        await f.peer.setTreeReadCorrupt(false)
        _ = try await f.owner.write(TreeImportTests.request(contents: nil), create: true, progress: Progress(totalUnitCount: 1))
        recovery.treeImport!.localRetirementStarted = true
        let directory = f.owner.staging.root.appendingPathComponent(head.tree.id.uuidString.lowercased() + ".tree")
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let retained = outside.appendingPathComponent("keep.txt"), bytes = Data("outside recovery".utf8)
        try bytes.write(to: retained)
        let calls = await f.peer.counts().2
        for mode in 0..<3 {
            try f.owner.staging.save(recovery)
            if mode == 1 {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try Data([1, 2, 3]).write(to: directory.appendingPathComponent("partial-retirement"))
            } else if mode == 2 { try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside) }
            await ProviderTreeImport(mutations: f.owner).cleanPublished(&recovery)
            let saved = try f.owner.staging.load(recovery.key)
            try mutationCheck(mode == 2 ? saved != nil : saved == nil,
                              "Postcommit local retirement was not idempotent or followed a symlink")
        }
        let finalCalls = await f.peer.counts().2
        try mutationCheck(calls == finalCalls && (try Data(contentsOf: retained)) == bytes,
                          "Local retirement contacted NAS or removed bytes outside its UUID snapshot")
        print("PASS postcommit retirement resumes with missing/partial snapshot and refuses a symlink without NAS operations")
    }

    private static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
}
