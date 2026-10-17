import FileProvider
import Foundation
import MyDriveCore

/// One native delete callback owns discovery and execution. Core persists its
/// immutable frontier; macOS owns retries, and no independent deletion pump runs.
struct ProviderRecursiveDelete: Sendable {
    let mutations: ProviderMutations
    let versions: DomainVersionSnapshot
    let published: @Sendable () async -> Void

    func delete(id: String, contentVersion: Data, metadataVersion: Data,
                context: DeletionRequestContext, progress: Progress) async throws {
        try await mutations.checkActive()
        try await mutations.refuseUnsupportedPackageDeletion(id: id)
        if let durable = try await mutations.catalog.domainVersionState() { try versions.publishCommitted(durable) }
        let originalKey = MutationInput.recursiveDeletionID(id: id, content: contentVersion,
            metadata: metadataVersion, context: context.issuedContextID)
        if try await mutations.catalog.mutationResult(key: originalKey) != nil {
            progress.completedUnitCount = progress.totalUnitCount; return
        }
        var status: RecursiveDeleteStatus
        do { status = try await prepare(id: id, content: contentVersion, metadata: metadataVersion, context: context) }
        catch let error as CapturedDeletionConflict { throw await refusal(error, rootID: id, scope: nil) }
        if status.phase == .completed { progress.completedUnitCount = progress.totalUnitCount; return }
        progress.totalUnitCount = -1
        progress.completedUnitCount = 0
        var representationQualified = false
        while status.phase != .completed {
            try await mutations.checkActive()
            let work = try await mutations.catalog.nextRecursiveDeleteWork(key: status.key, limit: 64)
            guard !work.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            for unit in work {
                try await mutations.checkActive()
                switch unit {
                case .capture(let item, let path, let scope):
                    try await refusePackageWork(item: item, path: path, status: status)
                    let scan = try await mutations.catalog.beginScan(of: item.id)
                    do {
                        let directory = try await mutations.remote.scopedList(path, SMBDeleteScope(scope)) { entries in
                            try await mutations.checkActive()
                            guard try !entries.contains(where: { try mutations.isPackageDirectory($0) }) else {
                                throw CapturedDeletionConflict(message: "This folder contains a package whose replacement cannot yet be synchronized safely. Its NAS contents are preserved.")
                            }
                            try await mutations.catalog.stage(entries, in: scan)
                        }
                        try await mutations.checkActive()
                        status = try await mutations.catalog.captureDeleteDirectory(key: status.key, scan: scan, directory: directory.observation)
                        await published()
                    } catch {
                        try? await mutations.catalog.abandonScan(scan)
                        try await blocked(error, itemID: item.id, rootKey: status.key)
                        throw await refusal(error, rootID: status.rootID, scope: SMBDeleteScope(status.scope))
                    }
                case .remove(let item, let path, let parent, let operationKey, let scope):
                    if !representationQualified {
                        do { try await qualifyFrozenRepresentation(key: status.key) }
                        catch {
                            try await blocked(error, itemID: status.rootID, rootKey: status.key)
                            throw await refusal(error, rootID: status.rootID, scope: SMBDeleteScope(status.scope))
                        }
                        representationQualified = true
                    }
                    try await refusePackageWork(item: item, path: path, status: status)
                    if progress.totalUnitCount < 0 {
                        progress.totalUnitCount = status.totalNodes
                        progress.completedUnitCount = status.removedNodes
                    }
                    do {
                        let childKey = try await mutations.deleteCaptured(rootKey: status.key, item: item, path: path,
                            parentIdentity: parent, operationKey: operationKey, scope: SMBDeleteScope(scope))
                        // Persist progress and the next native version together.
                        // Publish the immutable getter immediately after commit,
                        // even if cancellation arrived during that transaction.
                        let checkpoint = try versions.nextCheckpoint()
                        status = try await mutations.catalog.recordRecursiveDeleteProgress(key: status.key,
                            updates: [.removed(itemID: item.id, key: childKey)], advancingDomainVersion: checkpoint)
                        if let durable = status.domainVersionState { try versions.publishCommitted(durable) }
                        progress.completedUnitCount = status.removedNodes
                        await published()
                        mutations.finishCapturedDelete(childKey)
                    } catch {
                        try await blocked(error, itemID: item.id, rootKey: status.key)
                        throw await refusal(error, rootID: status.rootID, scope: SMBDeleteScope(status.scope))
                    }
                }
            }
        }
        progress.totalUnitCount = status.totalNodes
        progress.completedUnitCount = status.totalNodes
    }

    private func qualifyFrozenRepresentation(key: UUID) async throws {
        var afterID: String?
        while true {
            try await mutations.checkActive()
            let page = try await mutations.catalog.recursiveDeleteInventory(key: key, afterID: afterID, limit: 128)
            guard try !page.contains(where: { try mutations.isPackageDirectory($0.entry) }) else {
                throw CapturedDeletionConflict(message: "This deletion contains a package whose replacement is not yet supported. Remaining NAS contents are preserved.")
            }
            guard page.count == 128, let last = page.last else { return }
            afterID = last.id
        }
    }

    private func refusePackageWork(item: CatalogItem, path: String, status: RecursiveDeleteStatus) async throws {
        guard try MutationRepresentationPolicy.containsPackageDirectory(path: path, kind: item.entry.kind,
            registryAvailable: mutations.packageRegistryAvailable) else { return }
        let error = CapturedDeletionConflict(message: "Package deletion and replacement are temporarily unavailable. Its NAS contents are preserved.")
        try await blocked(error, itemID: item.id, rootKey: status.key)
        throw await refusal(error, rootID: status.rootID, scope: SMBDeleteScope(status.scope))
    }

    private func prepare(id: String, content: Data, metadata: Data,
                         context: DeletionRequestContext) async throws -> RecursiveDeleteStatus {
        guard id != Catalog.rootID else { throw CocoaError(.fileWriteNoPermission) }
        let key = MutationInput.recursiveDeletionID(id: id, content: content, metadata: metadata,
                                                   context: context.issuedContextID)
        if let prior = try await mutations.catalog.recursiveDeleteStatus(rootID: id, contextID: context.issuedContextID) {
            return prior
        }
        guard let item = try await mutations.catalog.item(id: id), item.entry.kind == .directory,
              let parentID = item.parentID else {
            throw MutationInput.unsupported("The selected folder needs a refresh before it can be deleted safely.")
        }
        guard !item.isDeleted, content == Data(item.entry.contentVersion.utf8),
              metadata == Data(item.entry.metadataVersion.utf8) else {
            throw CapturedDeletionConflict(message: "The selected folder changed before this deletion began. Refresh it before trying again.")
        }
        let parent = try await mutations.preparation.verifiedParent(parentID)
        let path: String
        if let current = try await mutations.catalog.relativePath(id: id) { path = current }
        else if let parentPath = try await mutations.catalog.relativePath(id: parentID) {
            path = ProviderMutations.join(parentPath, item.entry.name)
        } else { throw MutationInput.unsupported("The selected folder moved. Its previous deletion inventory is preserved.") }
        guard let observed = try await mutations.remote.stat(path), observed.directory,
              observed.attributes & 0x400 == 0, observed.objectIdentity == item.entry.objectIdentity,
              observed.name.utf8.elementsEqual(item.entry.name.utf8),
              MutationPreparation.matches(observed, content: content, metadata: metadata) else {
            throw CapturedDeletionConflict(message: "The NAS folder changed before this deletion began. Its current contents are preserved.")
        }
        let intent = JournalIntent(idempotencyKey: key, itemID: id, expectedVersion: item.entry.contentVersion,
            action: .deleteTree, expectedMetadataVersion: item.entry.metadataVersion,
            sourcePath: path, baseEntry: item.entry,
            deletionContextID: context.issuedContextID?.uuidString.lowercased())
        return try await mutations.catalog.prepareRecursiveDelete(intent: intent,
            rootParentIdentity: RemoteObjectIdentity(indexNumber: parent.index_number, createdFiletime: parent.created_filetime),
            requestContext: context.archive)
    }

    /// Definite version/feature conflicts restore the still-qualified selected
    /// folder. Network/authentication/cancellation and namespace-fence refusals
    /// retain their native retry semantics and never publish a replacement root.
    private func refusal(_ error: any Error, rootID: String, scope: SMBDeleteScope?) async -> any Error {
        let permanent = error is CapturedDeletionConflict || (error as? CatalogError) == .invalidEntry ||
            (error as? SMBClientError).map { if case .unsupportedFeature = $0 { true } else { false } } == true
        guard permanent else { return error }
        do {
            guard let item = try await mutations.catalog.item(id: rootID), !item.isDeleted,
                  let parentID = item.parentID, let path = try await mutations.catalog.relativePath(id: rootID) else { return error }
            let observed: SMBEntry?
            if let scope {
                guard path.utf8.elementsEqual(scope.root_path.utf8),
                      item.entry.objectIdentity.map(SMBMutationRequest.ParentIdentity.init) == scope.root else { return error }
                observed = try await mutations.remote.scopedStat(path, scope)
            } else {
                _ = try await mutations.preparation.verifiedParent(parentID)
                observed = try await mutations.remote.stat(path)
            }
            guard let observed, observed.directory, observed.attributes & 0x400 == 0,
                  observed.objectIdentity == item.entry.objectIdentity else { return error }
            return try await mutations.deletionRejected(id: rootID, parentID: parentID, entry: observed.observation,
                message: (error as? CapturedDeletionConflict)?.message)
        } catch let failure as SMBClientError {
            switch failure { case .authenticationRequired, .serverUnreachable, .cancelled: return failure; default: return error }
        } catch { return error }
    }

    private func blocked(_ error: any Error, itemID: String, rootKey: UUID) async throws {
        if error is CancellationError || Task.isCancelled { return }
        let value = ProviderErrors.translate(error) as NSError
        let code = "native:\(value.domain.prefix(96)):\(value.code)"
        let checkpoint = try versions.nextCheckpoint()
        let status = try await mutations.catalog.recordRecursiveDeleteProgress(key: rootKey,
            updates: [.blocked(itemID: itemID, code: code)], advancingDomainVersion: checkpoint)
        if let durable = status.domainVersionState { try versions.publishCommitted(durable) }
        await published()
    }
}

