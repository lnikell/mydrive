import FileProvider
import Foundation
import MyDriveCore

/// NEW directory contents only. A complete private payload is published by one
/// guarded rename; existing package replacement remains a separate, refused flow.
struct ProviderTreeImport: Sendable {
    let mutations: ProviderMutations

    /// One routing rule covers initial contents, Core-owned retries and input
    /// retained before Core preparation. Binding a create template is durable.
    func handles(_ input: MutationInput, create: Bool) async throws -> Bool {
        guard input.kind == .directory else { return false }
        if input.contents != nil {
            guard create else { throw MutationInput.unsupported("Whole-folder replacement cannot be uploaded safely yet. Its local contents are preserved.") }
            return true
        }
        guard create else { return false }
        let rootID = try await mutations.catalog.providerID(forCreateTemplate: input.id)
        let inCatalog = try await mutations.catalog.treeImportStatus(rootID: rootID) != nil
        if inCatalog { return true }
        return try hasLocalRecovery(rootID: rootID)
    }

    private func hasLocalRecovery(rootID: String) throws -> Bool {
        guard let plan = try mutations.staging.load(Self.operationKey(rootID: rootID)) else { return false }
        guard plan.itemID == rootID, plan.treeImport != nil else { throw CocoaError(.fileReadCorruptFile) }
        return true
    }

    func create(_ input: MutationInput, progress: Progress) async throws -> CatalogItem {
        try await mutations.checkActive()
        progress.totalUnitCount = -1; progress.completedUnitCount = 0
        try await mutations.refuseUnsupportedPackageWrite(input, create: true)
        let rootID = try await mutations.catalog.providerID(forCreateTemplate: input.id)
        let key = Self.operationKey(rootID: rootID)
        var status = try await mutations.catalog.treeImportStatus(rootID: rootID)
        if let status, status.layoutVersion != 2 { throw legacyLayout() }
        var candidate: LocalTreeSnapshot?
        if let source = input.contents { candidate = try await LocalTreeSnapshot.capture(source, in: mutations.staging) }
        else { candidate = nil }
        if status == nil, let saved = try mutations.staging.load(key), let retained = saved.treeImport {
            guard saved.itemID == rootID, saved.parentID == input.parentID,
                  saved.filename.utf8.elementsEqual(input.filename.utf8),
                  candidate.map({ Self.sameTree($0.reference, retained.tree) }) ?? true else {
                throw MutationInput.unsupported("This folder has a different preserved import. Both local snapshots are retained for recovery.")
            }
            // Keep an independently captured copy until the prior durable
            // input has actually been validated. A damaged recovery index
            // must not cause the new complete copy to be discarded first.
            let recovered = try LocalTreeSnapshot.load(retained.tree, in: mutations.staging)
            if let fresh = candidate, fresh.reference.id != retained.tree.id {
                try await recovered.validateContents()
                try fresh.discard()
            }
            candidate = recovered
        }
        if let existing = status {
            guard existing.parentID == input.parentID, existing.filename.utf8.elementsEqual(input.filename.utf8),
                  candidate.map({ $0.reference.nodeCount == existing.tree.nodeCount && $0.reference.totalBytes == existing.tree.totalBytes &&
                      $0.reference.sha256 == existing.tree.sha256 }) ?? true else {
                throw MutationInput.unsupported("This folder already has a different pending import. Both its original recovery record and the new local snapshot are preserved.")
            }
            if let candidate, candidate.reference.id != existing.tree.id {
                if existing.phase != .published {
                    try await LocalTreeSnapshot.load(existing.tree, in: mutations.staging).validateContents()
                }
                try candidate.discard()
            }
        } else {
            guard let candidate else { throw MutationInput.unsupported("This folder has no contents available to import. Its local contents are preserved.") }
            status = try await prepare(input, rootID: rootID, key: key, snapshot: candidate)
        }
        guard var current = status else { throw SMBClientError.invalidResponse }
        let aggregate = try TreeWorkProgress.configure(progress, tree: current.tree)
        if current.phase == .published { return try await complete(current, progress: progress) }
        let snapshot = try LocalTreeSnapshot.load(current.tree, in: mutations.staging)
        if current.phase == .building { current = try await freeze(current, snapshot: snapshot) }
        var preparedForVerification = false
        while current.phase != .published {
            try await mutations.checkActive()
            let work = try await mutations.catalog.nextTreeImportWork(key: current.key, limit: 16)
            guard !work.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            if let publish = work.compactMap({ item -> UUID? in
                if case .mutation(.publish, let intent, _, _) = item { return intent.idempotencyKey }
                return nil
            }).first {
                try await settleChildren(current, publishing: publish)
            } else if !preparedForVerification, work.contains(where: { item in
                switch item { case .verifyFile, .verifyDirectory: return true; case .mutation: return false }
            }) {
                try await settleChildren(current)
                preparedForVerification = true
            }
            let frontierStatus = current
            try await TreeImportFrontier.perform(work, progress: aggregate) { item, workProgress in
                _ = try await perform(item, status: frontierStatus, snapshot: snapshot, progress: workProgress)
            }
            // Every child and its helper is drained before selecting another
            // frontier. Its receipts may have completed out of order.
            guard let latest = try await mutations.catalog.treeImportStatus(rootID: current.rootID) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            current = latest
        }
        return try await complete(current, progress: progress)
    }

    private func prepare(_ input: MutationInput, rootID: String, key: UUID, snapshot: LocalTreeSnapshot) async throws -> TreeImportStatus {
        var plan = MutationPlan(key: key, itemID: rootID, parentID: input.parentID,
            filename: input.filename, steps: [], preservedOriginal: nil)
        plan.treeImport = TreeImportLocalState(tree: snapshot.reference)
        // The requested name and all local bytes survive even a preflight
        // failure. No remote mutation occurs until the Core intake is sealed.
        try mutations.staging.save(plan)
        guard let parentPath = try await mutations.catalog.relativePath(id: input.parentID) else {
            throw MutationInput.unsupported("The destination folder needs a refresh. The complete local folder is preserved for retry.")
        }
        let parent = try await mutations.preparation.verifiedParent(input.parentID)
        let destination = ProviderMutations.join(parentPath, input.filename)
        guard try await mutations.remote.stat(destination) == nil else {
            throw try await mutations.preparation.collision(parentID: input.parentID, name: input.filename)
        }
        let intent = JournalIntent(idempotencyKey: key, itemID: rootID, expectedVersion: nil,
            action: .create(parentID: input.parentID, name: input.filename, kind: .directory),
            createTemplateID: input.id, destinationPath: destination, tree: snapshot.reference)
        let scope = TreeImportScope(parentPath: parentPath,
            parentIdentity: .init(indexNumber: parent.index_number, createdFiletime: parent.created_filetime),
            arenaName: ".mydrive-" + key.uuidString.lowercased() + ".tree")
        try await mutations.checkActive()
        return try await mutations.catalog.prepareTreeImport(intent: intent, scope: scope)
    }

    private func freeze(_ original: TreeImportStatus, snapshot: LocalTreeSnapshot) async throws -> TreeImportStatus {
        var current = original, cursor: String?
        while true {
            try await mutations.checkActive()
            let page = try snapshot.entries(after: cursor)
            guard let last = page.last else { break }
            current = try await mutations.catalog.stageTreeImport(key: current.key, entries: page)
            cursor = last.path
        }
        cursor = nil
        while true {
            try await mutations.checkActive()
            let page = try snapshot.sealedDirectories(after: cursor)
            guard let last = page.last else { break }
            current = try await mutations.catalog.stageTreeImport(key: current.key, entries: [], sealedDirectories: page)
            cursor = last
        }
        return try await mutations.catalog.stageTreeImport(key: current.key, entries: [], isComplete: true)
    }

    private func perform(_ work: TreeImportWork, status: TreeImportStatus, snapshot: LocalTreeSnapshot,
                         progress: TreeWorkProgress) async throws -> TreeImportStatus {
        switch work {
        case .mutation(let step, let intent, let parent, let destinationParent):
            return try await performMutation(step: step, intent: intent, parent: parent,
                destinationParent: destinationParent, status: status, snapshot: snapshot, progress: progress)
        case .verifyFile(let item, let path, let payload):
            let scope = try treeScope(status)
            let temporary = snapshot.directory.appendingPathComponent("verify-" + UUID().uuidString.lowercased())
            defer { try? FileManager.default.removeItem(at: temporary) }
            let observed = try await mutations.remote.treeRead(path, temporary, scope, progress.received)
            let hash = try TreeImportVerification.hash(temporary, expectedBytes: payload.size)
            guard hash == payload.sha256 else { throw SMBClientError.invalidResponse }
            try await mutations.checkActive()
            return try await mutations.catalog.recordTreeImportProgress(key: status.key,
                update: .fileVerified(itemID: item.id, entry: observed, sha256: hash))
        case .verifyDirectory(let item, let path, let scan):
            let catalog = mutations.catalog, key = status.key, active = mutations.checkActive
            let directory = try await mutations.remote.treeList(path, treeScope(status)) { entries in
                try await active()
                _ = try await catalog.recordTreeImportProgress(key: key,
                    update: .directoryPage(itemID: item.id, scanID: scan, entries: entries))
            }
            try await mutations.checkActive()
            return try await catalog.recordTreeImportProgress(key: key,
                update: .directoryComplete(itemID: item.id, scanID: scan, entry: directory.observation))
        }
    }

    private func complete(_ status: TreeImportStatus, progress: Progress) async throws -> CatalogItem {
        guard status.layoutVersion == 2 else { throw legacyLayout() }
        guard let result = status.result, let root = result.items.first(where: { $0.id == status.rootID }) else {
            throw SMBClientError.invalidResponse
        }
        if var plan = try mutations.staging.load(status.key) { await cleanPublished(&plan, status: status) }
        try await mutations.checkActive()
        progress.completedUnitCount = progress.totalUnitCount
        return root
    }

    func treeScope(_ status: TreeImportStatus) throws -> SMBTreeScope {
        guard let arena = status.arena?.objectIdentity else { throw CocoaError(.fileReadCorruptFile) }
        guard status.layoutVersion == 2 else { throw legacyLayout() }
        return SMBTreeScope(arena_path: status.arenaPath, arena: .init(arena), parent: .init(status.scope.parentIdentity))
    }

    func legacyLayout() -> NSError {
        MutationInput.unsupported("This folder import uses an older staging layout. Its local contents and recovery records are preserved.")
    }

    private static func operationKey(rootID: String) -> UUID {
        MutationInput.uuid(for: Data(("tree-create-v1:" + rootID).utf8))
    }

    private static func sameTree(_ left: StagedTreeReference, _ right: StagedTreeReference) -> Bool {
        left.nodeCount == right.nodeCount && left.totalBytes == right.totalBytes && left.sha256 == right.sha256
    }
}
