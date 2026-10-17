import Testing
@testable import MyDriveCore

@Suite struct TreeImportPublicationTests {
    @Test func everyPrivateOperationResolvesItsDurableOwnerBeforeGenericMaintenance() async throws {
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("body")])
        let frozen = try await trial.freeze()
        #expect(try await trial.catalog.treeImportOwner(operationKey: frozen.key)?.key == frozen.key)
        #expect(try await trial.catalog.treeImportOwner(operationKey: mutationUUID()) == nil)
        var keys: [MutationTestKey] = []
        for _ in 0..<30 {
            let work = try await trial.catalog.nextTreeImportWork(key: frozen.key)
            for item in work {
                if case .mutation(_, let intent, _, _) = item {
                    let before = try #require(try await trial.catalog.treeImportOwner(operationKey: intent.idempotencyKey))
                    #expect(before.key == frozen.key && before.phase == .frozen)
                    keys.append(intent.idempotencyKey)
                }
                _ = try await trial.apply(item)
            }
            if try await trial.catalog.treeImportStatus(rootID: frozen.rootID)?.phase == .published { break }
        }
        #expect(keys.count == 6) // Arena, two create/place pairs and publication.
        let reopened = try Catalog(databaseURL: trial.fixture.url)
        for key in keys {
            let owner = try #require(try await reopened.treeImportOwner(operationKey: key))
            #expect(owner.phase == .published && owner.result?.items.first?.id == frozen.rootID)
            #expect(try await reopened.operation(key: key)?.intent.tree == nil)
        }
    }

    @Test func canonicalChildKeyIsBoundBeforeRpcAndScratchAuthorityDoesNotChange() async throws {
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory)])
        let frozen = try await trial.freeze()
        let first = try #require(try await trial.catalog.nextTreeImportWork(key: frozen.key).first)
        guard case .mutation(let step, let expected, _, _) = first else { throw CatalogError.invalidEntry }
        let previous = JournalIntent(itemID: expected.itemID, expectedVersion: expected.expectedVersion,
            action: expected.action, destinationPath: expected.destinationPath)
        let canonical = try await trial.catalog.enqueue(previous)
        #expect(canonical.intent.idempotencyKey != expected.idempotencyKey)
        let bound = try await trial.catalog.enqueueTreeImportChild(key: frozen.key, step: step, intent: expected)
        #expect(bound == canonical)
        let reopened = try Catalog(databaseURL: trial.fixture.url)
        let replay = try #require(try await reopened.nextTreeImportWork(key: frozen.key).first)
        guard case .mutation(_, let recovered, _, _) = replay else { throw CatalogError.invalidEntry }
        #expect(recovered.idempotencyKey == canonical.intent.idempotencyKey)
        #expect(recovered.destinationPath == expected.destinationPath)
        _ = try await trial.apply(replay, in: reopened)
        let create = try #require(try await reopened.nextTreeImportWork(key: frozen.key).first)
        guard case .mutation(.create, let createIntent, _, _) = create else { throw CatalogError.invalidEntry }
        let duplicate = JournalIntent(itemID: createIntent.itemID, expectedVersion: nil,
            action: createIntent.action, destinationPath: createIntent.destinationPath)
        // This is a private-parent operation, so only the manifest can qualify
        // it. Seed a prior canonical journal record to exercise dedupe recovery.
        let db = try SQLiteConnection(url: trial.fixture.url, cacheKiB: 2_048)
        try insertTreeTestOperation(duplicate, in: db)
        let returned = try await reopened.enqueueTreeImportChild(key: frozen.key, step: .create, intent: createIntent)
        #expect(returned.intent.idempotencyKey == duplicate.idempotencyKey)
        let again = try #require(try await reopened.nextTreeImportWork(key: frozen.key).first)
        guard case .mutation(.create, let frozenScratch, _, _) = again else { throw CatalogError.invalidEntry }
        #expect(frozenScratch.destinationPath == createIntent.destinationPath)
        #expect(frozenScratch.idempotencyKey == duplicate.idempotencyKey)
        let completed = try await trial.finish(in: reopened)
        #expect(completed.phase == .published)
    }

    @Test func replacedSelectedParentAfterRemotePublishCannotPartiallyCommitCatalog() async throws {
        let parent = RemoteEntry(name: "Parent", kind: .directory, contentVersion: "p", metadataVersion: "p",
                                 objectIdentity: .init(indexNumber: 100, createdFiletime: 101))
        let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("body")], parent: parent)
        let frozen = try await trial.freeze()
        let work = try await trial.readyToPublish()
        guard case .mutation(let step, let intent, _, _) = work else { throw CatalogError.invalidEntry }
        let operation = try await trial.catalog.enqueueTreeImportChild(key: frozen.key, step: step, intent: intent)
        try await trial.catalog.transitionOperation(key: operation.intent.idempotencyKey, from: .queued, to: .executing)
        let final = try trial.outcome(step: step, intent: intent)
        let replacement = RemoteEntry(name: "Parent", kind: .directory, contentVersion: "new", metadataVersion: "new",
                                      objectIdentity: .init(indexNumber: 102, createdFiletime: 103))
        let scan = try await trial.catalog.beginScan()
        try await trial.catalog.stage([replacement], in: scan)
        try await trial.catalog.completeScan(scan)
        let generation = try await trial.catalog.generation(), anchor = try await trial.catalog.currentChangeAnchor()
        await #expect(throws: CatalogError.invalidParent) {
            try await trial.catalog.recordTreeImportProgress(key: frozen.key,
                update: .committed(step: .publish, key: operation.intent.idempotencyKey, entry: final, sha256: nil))
        }
        #expect(try await trial.catalog.item(id: frozen.rootID) == nil)
        #expect(try await trial.catalog.generation() == generation)
        #expect(try await trial.catalog.currentChangeAnchor() == anchor)
        #expect(try await trial.catalog.mutationResult(key: frozen.key) == nil)
        #expect(try await trial.catalog.mutationResult(key: operation.intent.idempotencyKey) == nil)
        #expect(try await trial.catalog.treeImportStatus(rootID: frozen.rootID)?.phase == .frozen)
        #expect(try await trial.catalog.operation(key: operation.intent.idempotencyKey)?.state == .executing)
    }

    @Test func refreshAliasOfSamePublishedObjectIsRetiredButDifferentDestinationIsPreserved() async throws {
        for matches in [false, true] {
            let trial = try await ImportTrial(entries: [.init(path: "", kind: .directory), importFile("body")])
            let status = try await trial.freeze()
            let work = try await trial.readyToPublish()
            guard case .mutation(_, let intent, _, _) = work, let base = intent.baseEntry else { throw CatalogError.invalidEntry }
            let alias = RemoteEntry(name: status.filename, kind: .directory, contentVersion: "observed", metadataVersion: "observed",
                objectIdentity: matches ? base.objectIdentity : .init(indexNumber: 900, createdFiletime: 901))
            let scan = try await trial.catalog.beginScan()
            try await trial.catalog.stage([alias], in: scan)
            try await trial.catalog.completeScan(scan)
            let aliasID = try #require(try await trial.catalog.child(named: status.filename, in: Catalog.rootID)?.id)
            if matches {
                let completed = try await trial.apply(work)
                #expect(completed.result?.items.count == 1 && completed.result?.tombstones == [aliasID])
                #expect(try await trial.catalog.item(id: aliasID)?.isDeleted == true)
                #expect(try await trial.catalog.child(named: status.filename, in: Catalog.rootID)?.id == status.rootID)
            } else {
                let generation = try await trial.catalog.generation(), anchor = try await trial.catalog.currentChangeAnchor()
                await #expect(throws: CatalogError.invalidParent) { try await trial.apply(work) }
                #expect(try await trial.catalog.item(id: aliasID)?.isDeleted == false)
                #expect(try await trial.catalog.item(id: status.rootID) == nil)
                #expect(try await trial.catalog.generation() == generation)
                #expect(try await trial.catalog.currentChangeAnchor() == anchor)
            }
        }
    }
}
