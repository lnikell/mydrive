import FileProvider
import Foundation
import MyDriveCore

enum MutationAcknowledgedTests {
    private static let hash = String(repeating: "a", count: 64)
    private static let key = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static func run() async throws -> Int {
        try resultMatrix()
        try persistedBinding()
        try await acknowledgedCrashRecovery()
        print("PASS ACK result roles, immutable allocation binding and real Catalog pre-commit crash recovery")
        return 3
    }

    private static func entry(_ name: String, bytes: Int64, id: UInt64 = 42) -> SMBEntry {
        SMBEntry(name: name, bytes: bytes, directory: false, index_number: id,
            created_filetime: 7, modified_filetime: 9, changed_filetime: 10, attributes: 32)
    }

    private static func request(source: String = "/owned/payload", contract: MutationSaveContract? = .acknowledgedSMBV2,
                                artifactContract: MutationSaveContract? = .acknowledgedSMBV2) -> SMBMutationRequest {
        let stage = ".mydrive-\(key.uuidString.lowercased()).stage"
        return SMBMutationRequest(operationID: key, kind: .createFile, path: "File.bin",
            parent: .init(.init(indexNumber: 1, createdFiletime: 1)),
            payload: .init(source: source, bytes: 3, sha256: hash),
            receipt: .init(staged: .init(path: stage, entry: entry(stage, bytes: 0), cleanup_safe: true,
                phase: .allocated, security_sha256: hash, saveContract: artifactContract)), saveContract: contract)
    }

    private static func result(kind: MutationContentEvidence.Kind = .smbAcknowledged,
                               contract: MutationSaveContract? = .acknowledgedSMBV2,
                               bytes: Int64 = 3, sha: String = hash, legacy: String? = nil,
                               id: UInt64 = 42) -> SMBMutationResult {
        .init(operation_id: key.uuidString.lowercased(), outcome: .committed, code: "committed",
            entry: entry("File.bin", bytes: 3, id: id), sha256: legacy, cleanup_pending: false, receipt: .init(),
            saveContract: contract, contentEvidence: .init(kind: kind, bytes: bytes, sha256: sha))
    }

    private static func refused(_ body: () throws -> Void) throws {
        do { try body(); throw MutationTestFailure(message: "Malformed ACK facts were accepted") }
        catch is SMBClientError { }
    }

    private static func resultMatrix() throws {
        let request = request()
        try result().validate(for: request, reconcile: false)
        try result(kind: .remoteSHA256).validate(for: request, reconcile: true)
        try result().validate(for: request) // Stored facts, not live authority.
        for invalid in [result(contract: nil), result(bytes: 4), result(sha: String(repeating: "b", count: 64)),
                        result(legacy: hash), result(id: 99)] {
            try refused { try invalid.validate(for: request, reconcile: false) }
        }
        try refused { try result(kind: .remoteSHA256).validate(for: request, reconcile: false) }
        try refused { try result().validate(for: request, reconcile: true) }
        try refused { try result().validate(for: self.request(artifactContract: nil), reconcile: false) }
        let staleStage = SMBMutationResult(operation_id: request.operation_id, outcome: .committed, code: "committed",
            entry: entry("File.bin", bytes: 3), sha256: nil, cleanup_pending: true, receipt: request.receipt,
            saveContract: .acknowledgedSMBV2, contentEvidence: .init(kind: .smbAcknowledged, bytes: 3, sha256: hash))
        try refused { try staleStage.validate(for: request, reconcile: false) }
        let legacy = SMBMutationResult(operation_id: request.operation_id, outcome: .committed, code: "committed",
            entry: entry("File.bin", bytes: 3), sha256: hash, cleanup_pending: false, receipt: .init())
        try legacy.validate(for: self.request(contract: nil, artifactContract: nil), reconcile: false)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        try mutationCheck(json["save_contract"] == nil && json["content_evidence"] == nil,
                          "Legacy result encoding gained nonnil proof fields")
        try refused { try legacy.validate(for: request, reconcile: false) }
        try refused { try result().validate(for: self.request(contract: nil, artifactContract: nil), reconcile: false) }
    }

    private static func persistedBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try MutationStaging(root: root.appendingPathComponent("Mutations"))
        let payload = StagedPayload(id: key, size: 3, sha256: hash)
        let intent = JournalIntent(idempotencyKey: key, itemID: "file", expectedVersion: nil,
            action: .create(parentID: Catalog.rootID, name: "File.bin", kind: .file), payload: payload,
            destinationPath: "File.bin", saveContract: .acknowledgedSMBV2)
        var plan = MutationPlan(key: key, itemID: "file", parentID: Catalog.rootID, filename: "File.bin",
            steps: [.init(request: request(source: staging.payloadURL(payload.id).path))], preservedOriginal: nil)
        try plan.qualifySave(intent, staging: staging)
        plan.recordSaveResult(result(), at: 0)
        try mutationCheck(plan.steps[0].result?.receipt.staged == nil && plan.steps[0].request.receipt.staged != nil,
                          "Terminal stage absence erased the immutable creator binding")
        try mutationCheck(plan.cleanupCandidates.isEmpty,
                          "Historical creator origin became a live cleanup candidate after publication")
        try staging.save(plan)
        let saved = try staging.load(key)!
        try saved.qualifySave(intent, staging: staging)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        for field in ["save_contract", "source", "bytes", "sha256", "path"] {
            var changed = json
            var steps = changed["steps"] as! [[String: Any]]
            var wire = steps[0]["request"] as! [String: Any]
            if field == "save_contract" { wire.removeValue(forKey: field) }
            else if field == "path" { wire[field] = "Foreign.bin" }
            else {
                var body = wire["payload"] as! [String: Any]
                if field == "bytes" { body[field] = 4 }
                else { body[field] = field == "source" ? "/foreign/payload" : String(repeating: "b", count: 64) }
                wire["payload"] = body
            }
            steps[0]["request"] = wire; changed["steps"] = steps
            let rebound = try JSONDecoder().decode(MutationPlan.self, from: JSONSerialization.data(withJSONObject: changed))
            do { try rebound.qualifySave(intent, staging: staging); throw MutationTestFailure(message: "Rebound saved role accepted: \(field)") }
            catch is CocoaError { } catch is SMBClientError { }
        }
        // A truly old retained input decodes nil; it cannot adopt today's choice.
        let recoveryInput = try MutationInput(item: WriteTemplate(id: "id", name: "File.bin"), fields: .contents, contents: nil)
        let recovery = MutationLocalRecovery(input: recoveryInput, payload: payload)
        let decoded = try JSONDecoder().decode(MutationLocalRecovery.self, from: JSONEncoder().encode(recovery))
        try mutationCheck(decoded.saveContract == nil, "Old retained input gained a new save contract")
    }

    private static func acknowledgedCrashRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        try Data("acknowledged source".utf8).write(to: source)
        let input = try MutationInput(item: WriteTemplate(id: "ack-template", name: "Ack.bin"),
            fields: [.filename, .parentItemIdentifier, .contents], contents: source)
        let peer = MutationPeer(), latch = CancellationLatch()
        let ownerRoot = root.appendingPathComponent("owner")
        let owner = try MutationTests.fixture(ownerRoot, peer, check: { try await latch.check() })
        await peer.cancelAfterPublication(latch)
        do {
            _ = try await owner.write(input, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Cancelled before Core commit was acknowledged")
        } catch is CancellationError { }
        let operation = try await owner.catalog.replayableOperations()[0]
        let saved = try owner.staging.load(operation.intent.idempotencyKey)!
        try mutationCheck(saved.steps[0].result?.content_evidence?.kind == .smbAcknowledged &&
            saved.steps[0].result?.receipt.staged == nil && saved.steps[0].request.receipt.staged?.phase == .allocated &&
            FileManager.default.fileExists(atPath: owner.staging.payloadURL(operation.intent.payload!.id).path),
            "Saved ACK lost creator/source facts before canonical completion")
        let restarted = try MutationTests.fixture(ownerRoot, peer)
        _ = try await restarted.write(input, create: true, progress: Progress(totalUnitCount: 1))
        let receipt = try await restarted.catalog.mutationResult(key: operation.intent.idempotencyKey)
        let roles = await peer.reconciliationRoles
        try mutationCheck(receipt?.contentEvidence?.kind == .remoteSHA256 && roles.contains(true),
                          "Unfinished saved ACK bypassed strict restart reconciliation")
        let calls = (await peer.counts()).2
        _ = try await restarted.write(input, create: true, progress: Progress(totalUnitCount: 1))
        try mutationCheck((await peer.counts()).2 == calls, "Completed Core callback replay made a NAS request")
    }
}
