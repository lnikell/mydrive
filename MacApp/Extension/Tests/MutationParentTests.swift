import FileProvider
import Foundation
import MyDriveCore
import Darwin

extension MutationTests {
    static func parentIdentity() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let parentPeer = MutationPeer()
        let parentAdapter = try fixture(root.appendingPathComponent("parent-identity"), parentPeer)
        let folder = await parentPeer.seed(path: "Folder", bytes: Data(), directory: true)
        let folderScan = try await parentAdapter.catalog.beginScan()
        try await parentAdapter.catalog.stage([folder.observation], in: folderScan)
        try await parentAdapter.catalog.completeScan(folderScan)
        let folderID = try await parentAdapter.catalog.children().items[0].id
        let childInput = try MutationInput(item: WriteTemplate(id: "child-template", parent: folderID, name: "Child.txt"),
            fields: [.filename, .parentItemIdentifier, .contents], contents: source)
        let child = try await parentAdapter.write(childInput, create: true, progress: Progress(totalUnitCount: 1))
        let childHash = await parentPeer.hash("Folder/Child.txt")
        try mutationCheck(child.parentID == folderID && childHash == MutationPeer.hash(bytes),
                          "A matching typed parent identity could not publish its child")
        let callsBeforeReplacement = await parentPeer.counts().2
        _ = await parentPeer.seed(path: "Folder", bytes: Data(), directory: true)
        let replacedInput = try MutationInput(item: WriteTemplate(id: "replacement-template", parent: folderID, name: "Other.txt"),
            fields: [.filename, .parentItemIdentifier, .contents], contents: source)
        do {
            _ = try await parentAdapter.write(replacedInput, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "A replaced parent accepted a stale Finder write")
        } catch MutationParentError.replaced(let id) { try mutationCheck(id == folderID, "Wrong replaced parent was reported") }
        try mutationCheck(await parentPeer.counts().2 == callsBeforeReplacement, "Parent preflight refusal performed a mutation")
        print("PASS typed cached parent identity permits its child and refuses a same-path replacement before any mutation")
        return 1
    }

    static func legacyParent() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let legacyPeer = MutationPeer()
        let legacyAdapter = try fixture(root.appendingPathComponent("legacy-parent"), legacyPeer)
        let legacyFolder = await legacyPeer.seed(path: "Legacy", bytes: Data(), directory: true)
        let legacyEntry = RemoteEntry(name: "Legacy", kind: .directory,
            contentVersion: legacyFolder.observation.contentVersion, metadataVersion: legacyFolder.observation.metadataVersion)
        let legacyScan = try await legacyAdapter.catalog.beginScan()
        try await legacyAdapter.catalog.stage([legacyEntry], in: legacyScan)
        try await legacyAdapter.catalog.completeScan(legacyScan)
        let legacyID = try await legacyAdapter.catalog.children().items[0].id
        let legacyInput = try MutationInput(item: WriteTemplate(id: "legacy-template", parent: legacyID, name: "Child.txt"),
            fields: [.filename, .parentItemIdentifier, .contents], contents: source)
        do {
            _ = try await legacyAdapter.write(legacyInput, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Opaque version text was adopted as a parent identity")
        } catch MutationParentError.refreshRequired(let id) { try mutationCheck(id == legacyID, "Wrong legacy parent requires refresh") }
        try mutationCheck(await legacyPeer.counts().2 == 0 && !MutationPreparation.sameIdentity(legacyEntry, legacyFolder.observation),
                          "Missing typed identity was inferred from an opaque version")
        print("PASS legacy identity-free metadata requires refresh and opaque versions are never parsed as object identity")
        return 1
    }

    static func parentReplacementAndUnsafeRecord() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let swappedPeer = MutationPeer()
        let swappedAdapter = try fixture(root.appendingPathComponent("parent-race"), swappedPeer)
        await swappedPeer.replaceParentAfterStage()
        let swappedInput = try MutationInput(item: WriteTemplate(id: "swapped-template", name: "Guarded.txt"),
            fields: [.filename, .parentItemIdentifier, .contents], contents: source)
        do {
            _ = try await swappedAdapter.write(swappedInput, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Parent replacement between stage and publish was acknowledged")
        } catch MutationParentError.replaced(_) {}
        let guardedOperation = try await swappedAdapter.catalog.replayableOperations()[0]
        let guardedPlan = try swappedAdapter.staging.load(guardedOperation.intent.idempotencyKey)!
        let guardedCounts = await swappedPeer.counts()
        try mutationCheck(guardedCounts.0 == 1 && guardedCounts.1 == 0 && guardedPlan.steps.count == 1 &&
            guardedPlan.filename == "Guarded.txt" && guardedPlan.steps[0].result?.code == "parent_changed" &&
            FileManager.default.fileExists(atPath: swappedAdapter.staging.payloadURL(guardedOperation.intent.payload!.id).path),
            "Parent refusal derived a conflict sibling or discarded its durable payload/receipt")
        print("PASS stage-to-publish parent replacement preserves the original request and payload without deriving a conflict sibling")
        let planURL = swappedAdapter.staging.root.appendingPathComponent(guardedOperation.intent.idempotencyKey.uuidString.lowercased() + ".json")
        var oldPlan = try JSONSerialization.jsonObject(with: Data(contentsOf: planURL)) as! [String: Any]
        var oldSteps = oldPlan["steps"] as! [[String: Any]]
        var oldRequest = oldSteps[0]["request"] as! [String: Any]
        oldRequest.removeValue(forKey: "parent"); oldSteps[0]["request"] = oldRequest; oldPlan["steps"] = oldSteps
        try JSONSerialization.data(withJSONObject: oldPlan).write(to: planURL)
        do {
            _ = try await swappedAdapter.write(swappedInput, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "An identity-free old durable request was replayed")
        } catch is DecodingError {}
        try mutationCheck(await swappedPeer.counts().2 == guardedCounts.2 &&
            FileManager.default.fileExists(atPath: swappedAdapter.staging.payloadURL(guardedOperation.intent.payload!.id).path) &&
            FileManager.default.fileExists(atPath: planURL.path), "Old unsafe request was sent or its retained recovery data was erased")
        print("PASS durable records missing required parent identity fail closed without remote replay or recovery-data deletion")
        return 2
    }

    static func cleanupParent() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let cleanupParentPeer = MutationPeer()
        let cleanupParentAdapter = try fixture(root.appendingPathComponent("cleanup-parent"), cleanupParentPeer)
        let cleanupBase = await cleanupParentPeer.seed(path: "Cleanup.txt", bytes: Data("old".utf8))
        let cleanupScan = try await cleanupParentAdapter.catalog.beginScan()
        try await cleanupParentAdapter.catalog.stage([cleanupBase.observation], in: cleanupScan)
        try await cleanupParentAdapter.catalog.completeScan(cleanupScan)
        let cleanupItem = try await cleanupParentAdapter.catalog.children().items[0]
        let frozenCleanupInput = try MutationInput(item: WriteTemplate(id: cleanupItem.id, name: "Cleanup.txt"), fields: [.contents], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(cleanupBase.observation.contentVersion.utf8),
                                                  metadataVersion: Data(cleanupBase.observation.metadataVersion.utf8)))
        await cleanupParentPeer.failNextCleanup()
        _ = try await cleanupParentAdapter.write(frozenCleanupInput, create: false, progress: Progress(totalUnitCount: 1))
        await cleanupParentPeer.replaceRoot()
        let cleanupReport = await cleanupParentAdapter.maintain()
        try mutationCheck(cleanupReport.cleanupPending == 1 && cleanupReport.retained == 0,
                          "Maintenance lost a receipt or cleaned through a replaced parent")
        print("PASS post-commit maintenance preserves the original frozen parent identity and retains cleanup after replacement")
        return 1
    }

    static func conflictParent() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let conflictParentPeer = MutationPeer()
        let conflictParentAdapter = try fixture(root.appendingPathComponent("conflict-parent"), conflictParentPeer)
        let conflictBase = await conflictParentPeer.seed(path: "Conflict.txt", bytes: Data("base".utf8))
        let conflictScan = try await conflictParentAdapter.catalog.beginScan()
        try await conflictParentAdapter.catalog.stage([conflictBase.observation], in: conflictScan)
        try await conflictParentAdapter.catalog.completeScan(conflictScan)
        let conflictItem = try await conflictParentAdapter.catalog.children().items[0]
        let conflictParentInput = try MutationInput(item: WriteTemplate(id: conflictItem.id, name: "Conflict.txt"), fields: [.contents], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(conflictBase.observation.contentVersion.utf8),
                                                  metadataVersion: Data(conflictBase.observation.metadataVersion.utf8)))
        await conflictParentPeer.replaceParentOnFileConflict()
        do {
            _ = try await conflictParentAdapter.write(conflictParentInput, create: false, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Conflict recovery rebound to the replacement share root")
        } catch MutationParentError.replaced(_) {}
        let conflictOperation = try await conflictParentAdapter.catalog.replayableOperations()[0]
        let conflictPlan = try conflictParentAdapter.staging.load(conflictOperation.intent.idempotencyKey)!
        let conflictCounts = await conflictParentPeer.counts()
        try mutationCheck(conflictCounts.0 == 0 && conflictCounts.1 == 0 && conflictPlan.retainedRequests.count == 1 &&
            conflictPlan.steps[0].request.parent == conflictPlan.retainedRequests[0].parent &&
            conflictPlan.steps[0].request.path.utf8.starts(with: "Conflict (conflict ".utf8) &&
            FileManager.default.fileExists(atPath: conflictParentAdapter.staging.payloadURL(conflictOperation.intent.payload!.id).path),
            "Conflict recovery adopted a fresh parent or erased its retained local bytes")
        print("PASS conflict recovery inherits the frozen parent snapshot and cannot publish into a replacement share root")
        return 1
    }

}
