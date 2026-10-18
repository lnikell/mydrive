import Testing
@testable import MyDriveCore

@Suite struct MutationSaveContractTests {
    @Test func legacyEncodingAndFingerprintMatchTheOriginalCoreArchive() throws {
        let legacy = contractIntent()
        #expect(legacy.requestFingerprint == "bbc94b62b481aa42dd6acbe35c249474f186e0cd5364550e86008d0ba25a6555")
        #expect(try sortedIntentJSON(legacy) == legacyContractJSON())
        #expect(try intentJSON(legacyContractJSON()).saveContract == nil)
        let current = contractIntent(.acknowledgedSMBV2)
        #expect(current.requestFingerprint != legacy.requestFingerprint)
        #expect(try intentJSON(sortedIntentJSON(current)) == current)
        #expect(throws: (any Error).self) {
            try intentJSON(legacyContractJSON().dropLast() + #", "saveContract":"unknown"}"#)
        }
    }

    @Test func contentEvidenceHasOneClosedBoundedShape() throws {
        let hash = String(repeating: "a", count: 64)
        #expect(try evidenceJSON(#"{"kind":"smb_acknowledged","bytes":42,"sha256":""# + hash + #""}"#) == evidence())
        for text in [
            #"{"kind":"unknown","bytes":42,"sha256":""# + hash + #""}"#,
            #"{"kind":"remote_sha256","bytes":-1,"sha256":""# + hash + #""}"#,
            #"{"kind":"remote_sha256","bytes":9223372036854775808,"sha256":""# + hash + #""}"#,
            #"{"kind":"remote_sha256","bytes":42,"sha256":"BAD"}"#,
            #"{"kind":"remote_sha256","bytes":42,"sha256":""# + hash + #"","trusted":true}"#,
            #"{"kind":"remote_sha256","sha256":""# + hash + #""}"#
        ] { #expect(throws: (any Error).self) { try evidenceJSON(text) } }
        #expect(!evidence(bytes: -1).isValid)
    }

    @Test func completionBindsEvidenceAndPreservesAnImmutableDurableReceipt() async throws {
        let fixture = try Fixture(), request = contractIntent(.acknowledgedSMBV2)
        try await fixture.catalog.enqueue(request)
        try await fixture.catalog.transitionOperation(key: request.idempotencyKey, from: .queued, to: .executing)
        let observed = contractEntry(request), generation = try await fixture.catalog.generation()
        for bad in [nil, evidence(bytes: 41), evidence(hash: String(repeating: "b", count: 64))] {
            await #expect(throws: CatalogError.invalidEntry) {
                try await fixture.catalog.commitMutation(key: request.idempotencyKey, upserts: [observed],
                    tombstones: [], contentEvidence: bad)
            }
        }
        #expect(try await fixture.catalog.generation() == generation)
        #expect(try await fixture.catalog.item(id: request.itemID) == nil)
        let saved = try await fixture.catalog.commitMutation(key: request.idempotencyKey, upserts: [observed],
            tombstones: [], contentEvidence: evidence())
        let reopened = try Catalog(databaseURL: fixture.url)
        #expect(saved.contentEvidence == evidence())
        #expect(try await reopened.mutationResult(key: request.idempotencyKey) == saved)
        #expect(try await reopened.commitMutation(key: request.idempotencyKey, upserts: [observed],
            tombstones: [], contentEvidence: evidence()) == saved)
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await reopened.commitMutation(key: request.idempotencyKey, upserts: [observed],
                tombstones: [], contentEvidence: evidence(.remoteSHA256))
        }
    }

    @Test func legacyCannotAcquireAcknowledgedEvidenceAndUncertainV2AcceptsRemoteHash() async throws {
        let legacyFixture = try Fixture(), legacy = contractIntent()
        try await legacyFixture.catalog.enqueue(legacy)
        try await legacyFixture.catalog.transitionOperation(key: legacy.idempotencyKey, from: .queued, to: .executing)
        await #expect(throws: CatalogError.invalidEntry) {
            try await legacyFixture.catalog.commitMutation(key: legacy.idempotencyKey,
                upserts: [contractEntry(legacy)], tombstones: [], contentEvidence: evidence())
        }
        let fixture = try Fixture(), request = contractIntent(.acknowledgedSMBV2)
        try await fixture.catalog.enqueue(request)
        try await fixture.catalog.transitionOperation(key: request.idempotencyKey, from: .queued, to: .executing)
        let reopened = try Catalog(databaseURL: fixture.url)
        try await reopened.recoverInterruptedOperations()
        #expect(try await reopened.operation(key: request.idempotencyKey)?.intent.saveContract == .acknowledgedSMBV2)
        let result = try await reopened.commitMutation(key: request.idempotencyKey, upserts: [contractEntry(request)],
            tombstones: [], contentEvidence: evidence(.remoteSHA256))
        #expect(result.contentEvidence?.kind == .remoteSHA256)
    }

    @Test func bodyContractCannotBeAttachedToDirectoryOrNamespaceWork() async throws {
        let fixture = try Fixture()
        let directory = JournalIntent(itemID: "invalid-dir", expectedVersion: nil,
            action: .create(parentID: Catalog.rootID, name: "dir", kind: .directory), saveContract: .acknowledgedSMBV2)
        await #expect(throws: CatalogError.invalidEntry) { try await fixture.catalog.enqueue(directory) }
        let removal = JournalIntent(itemID: "invalid-delete", expectedVersion: nil, action: .delete,
            payload: contractIntent().payload, saveContract: .acknowledgedSMBV2)
        await #expect(throws: CatalogError.invalidEntry) { try await fixture.catalog.enqueue(removal) }
    }

    @Test func treeRootFreezesFileChoiceAndStillRequiresItsFinalBodySweep() async throws {
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("file.bin")],
                                          name: "Ordinary folder", saveContract: .acknowledgedSMBV2)
        let status = try await trial.freeze(), reopened = try Catalog(databaseURL: trial.fixture.url)
        #expect(status.saveContract == .acknowledgedSMBV2)
        #expect(try await reopened.treeImportStatus(rootID: trial.intent.itemID)?.saveContract == .acknowledgedSMBV2)
        let arena = try #require(try await reopened.nextTreeImportWork(key: status.key).first)
        if case .mutation(_, let intent, _, _) = arena { #expect(intent.saveContract == nil) }
        _ = try await trial.apply(arena, in: reopened)
        let create = try #require(try await reopened.nextTreeImportWork(key: status.key).first)
        guard case .mutation(.create, let child, _, _) = create else { Issue.record("Expected file create"); return }
        #expect(child.saveContract == .acknowledgedSMBV2)
        let rebound = JournalIntent(idempotencyKey: child.idempotencyKey, itemID: child.itemID, expectedVersion: nil,
            action: child.action, payload: child.payload, destinationPath: child.destinationPath)
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await reopened.enqueueTreeImportChild(key: status.key, step: .create, intent: rebound)
        }
        _ = try await trial.apply(create, in: reopened)
        #expect(try await reopened.mutationResult(key: child.idempotencyKey)?.contentEvidence == evidence())
        let work = try await trial.placeAll(in: reopened)
        #expect(work.contains { if case .verifyFile = $0 { true } else { false } })
        #expect(try await reopened.item(id: trial.intent.itemID) == nil)
        _ = try await trial.finish(in: reopened)
        #expect(try await reopened.item(id: trial.intent.itemID)?.entry.kind == .directory)
        let receipt = try #require(try await reopened.mutationResult(key: child.idempotencyKey))
        try removeStoredRootContract(trial)
        await #expect(throws: CatalogError.idempotencyConflict) {
            try await reopened.recordTreeImportProgress(key: status.key,
                update: .committed(step: .create, key: child.idempotencyKey,
                    entry: receipt.items[0].entry, sha256: nil, contentEvidence: receipt.contentEvidence))
        }
    }
}
