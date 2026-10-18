import FileProvider
import Foundation
import MyDriveCore

/// The callback is the only driver. The OS retains dirty files, retries offline
/// work and schedules uploads; this module adds durable idempotency, not a queue
/// that independently uploads those same edits in the background.
struct ProviderMutations: Sendable {
    let catalog: Catalog
    let staging: MutationStaging
    let remote: MutationRemote
    let checkActive: @Sendable () async throws -> Void
    let packageRegistryAvailable: @Sendable () -> Bool
    let preferences: @Sendable () async throws -> UserPreferences
    let transferActivity: @Sendable (TreeTransferEvent) async -> Void

    init(catalog: Catalog, staging: MutationStaging, remote: MutationRemote,
         checkActive: @escaping @Sendable () async throws -> Void,
         packageRegistryAvailable: @escaping @Sendable () -> Bool = MutationRepresentationPolicy.registryIsAvailable,
         preferences: @escaping @Sendable () async throws -> UserPreferences = { UserPreferences() },
         transferActivity: @escaping @Sendable (TreeTransferEvent) async -> Void = { _ in }) {
        self.catalog = catalog; self.staging = staging; self.remote = remote
        self.checkActive = checkActive; self.packageRegistryAvailable = packageRegistryAvailable
        self.preferences = preferences; self.transferActivity = transferActivity
    }

    func write(_ requested: MutationInput, create: Bool, progress: Progress) async throws -> CatalogItem {
        try await checkActive()
        // Unsupported metadata stays pending with File Provider. Reading the
        // current item consumes no package content or namespace change.
        if !create, requested.hasOnlyUnsupportedMetadata {
            guard let current = try await catalog.item(id: requested.id), !current.isDeleted else {
                throw ProviderErrors.noSuchItem()
            }
            _ = try requested.mergingUnchanged(current)
            guard try await catalog.relativePath(id: current.id) != nil else {
                throw MutationInput.unsupported("The selected item's folder hierarchy needs a refresh. Its NAS contents are preserved.")
            }
            try await checkActive()
            progress.completedUnitCount = 1
            return current
        }
        if try await ProviderTreeImport(mutations: self).handles(requested, create: create) {
            return try await importTree(requested, progress: progress)
        }
        try await refuseUnsupportedPackageWrite(requested, create: create)
        let input = requested
        let hasContent = input.kind == .file && (create || input.fields.contains(.contents))
        if hasContent && input.contents == nil {
            if create {
                let bound = try await catalog.providerID(forCreateTemplate: input.id)
                if let existing = try await catalog.item(id: bound), !existing.isDeleted {
                    progress.completedUnitCount = 1
                    return existing
                }
            }
            throw MutationInput.unsupported("This file has no contents available to upload.")
        }
        var candidate = hasContent ? try await staging.stage(input.contents!) : nil
        var saveContract: MutationSaveContract? = hasContent ? .acknowledgedSMBV2 : nil
        let requestedKey = input.operationID(create: create, payload: candidate)
        // Repeated preflight failures for the same edit reuse its retained
        // bytes, instead of creating another unreferenced staged payload.
        if let fresh = candidate, let recovery = try staging.load(requestedKey)?.localRecovery {
            guard fresh.size == recovery.payload.size, fresh.sha256 == recovery.payload.sha256,
                  FileManager.default.fileExists(atPath: staging.payloadURL(recovery.payload.id).path) else {
                staging.discard(fresh)
                throw MutationInput.unsupported("This edited file needs recovery before it can be uploaded. Its local contents are preserved.")
            }
            staging.discard(fresh)
            candidate = recovery.payload
            saveContract = recovery.saveContract
        }
        var operation: JournalOperation
        do {
            if let existing = try await catalog.operation(key: requestedKey) {
                staging.discard(candidate)
                operation = existing
            } else {
                let effective: MutationInput
                if create { effective = input }
                else {
                    guard let current = try await catalog.item(id: input.id), !current.isDeleted else { throw ProviderErrors.noSuchItem() }
                    effective = try input.mergingUnchanged(current)
                    if !effective.fields.contains(.contents), effective.parentID == current.parentID,
                       effective.filename.utf8.elementsEqual(current.entry.name.utf8) {
                        staging.discard(candidate)
                        progress.completedUnitCount = 1
                        return current
                    }
                }
                let prepared = try await preparation.prepare(effective, create: create, key: requestedKey, payload: candidate, saveContract: saveContract)
                try staging.save(prepared.plan)
                operation = try await catalog.enqueue(prepared.intent)
                if operation.intent.idempotencyKey != requestedKey {
                    staging.discard(candidate)
                    try? staging.removePlan(requestedKey)
                }
            }
        } catch {
            // A missing/deleted item can be a delayed dirty callback. Retain
            // independent recovery evidence before reporting its preflight
            // failure; noSuchItem could authorize discarding the local edit.
            if try await catalog.operation(key: requestedKey) == nil {
                if let candidate {
                    var plan = try staging.load(requestedKey) ?? MutationPlan(key: requestedKey,
                        itemID: input.id, parentID: input.parentID, filename: input.filename,
                        steps: [], preservedOriginal: nil)
                    plan.localRecovery = MutationLocalRecovery(input: input, payload: candidate, saveContract: saveContract)
                    try staging.save(plan)
                    let translated = ProviderErrors.translate(error) as NSError
                    if translated.domain == NSFileProviderErrorDomain,
                       translated.code == NSFileProviderError.noSuchItem.rawValue {
                        throw MutationInput.unsupported("This edited file cannot yet be matched safely to the NAS. Its contents and recovery record are preserved on this Mac.")
                    }
                    throw error
                }
                try? staging.removePlan(requestedKey)
            }
            throw error
        }
        let key = operation.intent.idempotencyKey
        guard try await catalog.treeImportOwner(operationKey: key) == nil else {
            throw MutationInput.unsupported("This change belongs to a pending whole-folder import. Its local contents and recovery records are preserved.")
        }
        if let result = try await catalog.mutationResult(key: key) {
            if var plan = try staging.load(key) { await cleanup(plan: &plan) }
            progress.completedUnitCount = progress.totalUnitCount
            return try completedItem(result, id: operation.intent.itemID)
        }
        guard var plan = try staging.load(key) else {
            throw MutationInput.unsupported("An interrupted upload is missing its recovery record. Its local contents are preserved.")
        }
        try plan.qualifySave(operation.intent, staging: staging)
        let recovering = operation.state != .queued
        if operation.state == .queued || operation.state == .failed {
            if operation.state == .failed {
                operation = try await catalog.transitionOperation(key: key, from: .failed, to: .queued)
            }
            operation = try await catalog.transitionOperation(key: key, from: .queued, to: .executing)
        }
        let transfer = ContentFetchProgress(progress, expectedBytes: operation.intent.payload?.size ?? 1)
        do {
            try await performStep(0, plan: &plan, recovering: recovering,
                                  progress: { transfer.received($0) })
            if plan.steps[0].result?.code == "parent_changed" { throw MutationParentError.replaced(plan.parentID) }
            if plan.steps[0].result?.outcome == .conflict,
               operation.intent.payload != nil, !create {
                try await preserveConflict(plan: &plan, intent: operation.intent)
                try plan.qualifySave(operation.intent, staging: staging)
                try await performStep(0, plan: &plan, recovering: false,
                                      progress: { transfer.received($0) })
            }
            try requireCommitted(plan.steps[0], deleting: false, parentID: plan.parentID)
            if plan.steps.count > 1 {
                try await performStep(1, plan: &plan, recovering: true, progress: nil)
                if plan.steps[1].result?.code == "parent_changed" {
                    throw MutationParentError.replaced(plan.sourceParentID ?? Catalog.rootID)
                }
                if plan.steps[1].result?.outcome == .conflict {
                    // The new name already contains verified local bytes. Keep
                    // an intervening edit at the original path as a second ID.
                    try await preserveOriginal(plan: &plan, path: plan.steps[1].request.path,
                                               parentID: plan.sourceParentID ?? Catalog.rootID, allowMissing: true)
                } else { try requireCommitted(plan.steps[1], deleting: true, parentID: plan.sourceParentID ?? Catalog.rootID) }
            }
            try await checkActive()
            guard let entry = plan.steps[0].result?.entry else { throw SMBClientError.invalidResponse }
            if let payload = operation.intent.payload {
                guard entry.bytes == payload.size,
                      operation.intent.saveContract != nil || plan.steps[0].result?.sha256 == payload.sha256 else {
                    throw SMBClientError.invalidResponse
                }
            }
            var upserts = [CatalogMutationItem(id: plan.itemID, parentID: plan.parentID,
                                               entry: entry.observation)]
            if let original = plan.preservedOriginal { upserts.append(original) }
            let aliases = try await duplicateObservationIDs(for: upserts)
            let committed = try await catalog.commitMutation(key: key, upserts: upserts, tombstones: aliases,
                contentEvidence: plan.steps[0].result?.content_evidence)
            // After remote+database commit, cancellation must not make the bytes
            // appear uncommitted. OS callback replay returns this durable receipt.
            staging.discard(operation.intent.payload)
            await cleanup(plan: &plan)
            transfer.finish {}
            return try completedItem(committed, id: plan.itemID)
        } catch {
            if let latest = try? await catalog.operation(key: key), latest.state == .executing {
                _ = try? await catalog.transitionOperation(key: key, from: .executing, to: .uncertain)
            }
            let translated = ProviderErrors.translate(error) as NSError
            if operation.intent.payload != nil, translated.domain == NSFileProviderErrorDomain,
               translated.code == NSFileProviderError.noSuchItem.rawValue {
                throw MutationInput.unsupported("The NAS item disappeared before this upload could be confirmed. Its edited contents and recovery record are preserved on this Mac.")
            }
            if let failure = error as? SMBClientError {
                switch failure {
                case .changed: throw MutationInput.unsupported("The staged upload changed before it could be verified. Its local contents are preserved.")
                case .permissionDenied: throw CocoaError(.fileWriteNoPermission)
                default: break
                }
            }
            throw error
        }
    }

    private func importTree(_ input: MutationInput, progress: Progress) async throws -> CatalogItem {
        do { return try await ProviderTreeImport(mutations: self).create(input, progress: progress) }
        catch {
            let error = ProviderErrors.translate(error) as NSError
            if error.domain == NSFileProviderErrorDomain,
               [NSFileProviderError.noSuchItem.rawValue, NSFileProviderError.versionNoLongerAvailable.rawValue].contains(error.code) {
                throw MutationInput.unsupported("The folder import could not be confirmed. Its local contents and recovery records are preserved.")
            }
            throw error
        }
    }

    var preparation: MutationPreparation {
        MutationPreparation(catalog: catalog, staging: staging, remote: remote)
    }

    /// A refresh after a lost reply can observe the committed destination before
    /// the original callback publishes its stable ID. Retire only aliases of
    /// that exact remote object, never a different file at the same pathname.
    private func duplicateObservationIDs(for upserts: [CatalogMutationItem]) async throws -> [String] {
        let publishing = Set(upserts.map(\.id))
        var retired: [String] = []
        for value in upserts {
            if let observed = try await catalog.child(named: value.entry.name, in: value.parentID),
               !publishing.contains(observed.id) {
                guard MutationPreparation.sameIdentity(observed.entry, value.entry) else {
                    throw MutationInput.unsupported("The NAS destination changed during recovery. Local edits and recovery records are preserved.")
                }
                retired.append(observed.id)
            }
        }
        return retired
    }

    func performStep(_ index: Int, plan: inout MutationPlan, recovering: Bool,
                             progress: (@Sendable (Int64) -> Void)?) async throws {
        guard plan.steps.indices.contains(index) else { throw CocoaError(.fileReadCorruptFile) }
        if let saved = plan.steps[index].result { try saved.validate(for: plan.steps[index].request) }
        let savedV2Commit = plan.steps[index].request.save_contract != nil && plan.steps[index].result?.outcome == .committed
        if plan.steps[index].result?.outcome == .committed && !savedV2Commit { return }
        var reconcile = recovering || savedV2Commit || plan.steps[index].result?.outcome == .uncertain
        // At most: reconcile, two lost-allocation rotations, allocated/prepared
        // checkpoints, and publish. Retry scheduling remains with File Provider.
        for _ in 0..<8 {
            try await checkActive()
            let result = try await remote.mutate(plan.steps[index].request, reconcile, progress)
            try result.validate(for: plan.steps[index].request, reconcile: reconcile)
            if result.code == "allocation_unknown" {
                guard result.outcome == .uncertain,
                      plan.steps[index].request.receipt.staged == nil,
                      result.receipt.staged == nil else { throw SMBClientError.invalidResponse }
                if let archived = plan.steps[index].request.receipt.archived,
                   result.receipt.archived != archived { throw SMBClientError.invalidResponse }
            }
            plan.recordSaveResult(result, at: index)
            try staging.save(plan)
            if result.outcome == .uncertain, result.code == "allocation_unknown" {
                let unknown = plan.steps[index].request.sidecar("stage")
                if !plan.unresolvedAllocationPaths.contains(where: { $0.utf8.elementsEqual(unknown.utf8) }) {
                    plan.unresolvedAllocationPaths.append(unknown)
                    try staging.save(plan)
                }
                if result.receipt.archived != nil { return }
                try renewLostAllocation(index, plan: &plan)
                reconcile = false
                continue
            }
            switch result.outcome {
            case .committed, .conflict, .uncertain: return
            case .notApplied:
                if !["allocated", "prepared", "not_applied"].contains(result.code) { return }
                reconcile = false
            }
        }
        throw SMBClientError.invalidResponse
    }

    /// No bytes are sent before allocation acknowledgement. A lost ACK leaves
    /// an unowned pathname, which is recorded but never adopted or cleaned.
    private func renewLostAllocation(_ index: Int, plan: inout MutationPlan) throws {
        let previous = plan.steps[index].request
        guard [.createFile, .createDirectory, .replaceFile].contains(previous.kind),
              previous.receipt.staged == nil, previous.receipt.archived == nil,
              let previousID = UUID(uuidString: previous.operation_id) else { throw SMBClientError.invalidResponse }
        let unknown = previous.sidecar("stage")
        if !plan.unresolvedAllocationPaths.contains(where: { $0.utf8.elementsEqual(unknown.utf8) }) {
            plan.unresolvedAllocationPaths.append(unknown)
        }
        try staging.save(plan)
        guard plan.unresolvedAllocationPaths.count <= 2 else {
            throw MutationInput.unsupported("The NAS upload allocation could not be confirmed. Local contents and the unconfirmed NAS paths are preserved for recovery.")
        }
        let request = SMBMutationRequest(operationID: MutationInput.derivedID(previousID, "allocation-retry"),
            kind: previous.kind, path: previous.path, parent: previous.parent,
            destination: previous.destination, destinationParent: previous.destination_parent,
            expected: previous.expected, payload: previous.payload, deleteScope: previous.delete_scope,
            treeScope: previous.tree_scope, saveContract: previous.save_contract)
        plan.retainedRequests.append(previous)
        plan.steps[index] = .init(request: request)
        try staging.save(plan)
    }

    private func preserveConflict(plan: inout MutationPlan, intent: JournalIntent) async throws {
        guard let path = intent.sourcePath, let payload = intent.payload,
              let original = try await remote.stat(path) else {
            throw MutationInput.unsupported("The remote conflict needs attention. The local edited file is preserved.")
        }
        // Replacing a failed step is safe only if the server definitely reported
        // conflict. Keep its artifacts in the record; never infer upload success.
        let previous = plan.steps[0]
        guard previous.result?.receipt.archived == nil else {
            throw MutationInput.unsupported("An interrupted replacement retained the original NAS file for recovery.")
        }
        plan.filename = Self.conflictName(plan.filename, key: plan.key)
        // Conflict recovery cannot replace the already-durable parent guard
        // with a newer Catalog observation at the same pathname.
        let parentPath = previous.request.path.split(separator: "/", omittingEmptySubsequences: false)
            .dropLast().joined(separator: "/")
        let request = SMBMutationRequest(operationID: MutationInput.derivedID(plan.key, "conflict"), kind: .createFile,
            path: Self.join(parentPath, plan.filename), parent: previous.request.parent, payload: .init(source: staging.payloadURL(payload.id).path,
                                                                    bytes: payload.size, sha256: payload.sha256), saveContract: intent.saveContract)
        plan.retainedRequests.append(previous.request)
        plan.steps = [.init(request: request)]
        try await preserveOriginal(plan: &plan, path: path, parentID: plan.sourceParentID ?? Catalog.rootID, observed: original)
        try staging.save(plan)
    }

    private func preserveOriginal(plan: inout MutationPlan, path: String, parentID: String,
                                  observed: SMBEntry? = nil, allowMissing: Bool = false) async throws {
        let current: SMBEntry?
        if let observed { current = observed } else { current = try await remote.stat(path) }
        guard let original = current else {
            if allowMissing { plan.preservedOriginal = nil; try staging.save(plan); return }
            throw MutationInput.unsupported("The original NAS item moved during conflict recovery. Local edits are preserved.")
        }
        plan.preservedOriginal = CatalogMutationItem(
            id: try await catalog.providerID(forCreateTemplate: "conflict-original:\(plan.key.uuidString.lowercased())"),
            parentID: parentID, entry: original.observation)
        try staging.save(plan)
    }

    func requireCommitted(_ step: MutationPlan.Step, deleting: Bool, parentID: String) throws {
        guard let result = step.result else { throw SMBClientError.invalidResponse }
        if result.outcome == .committed { return }
        switch result.code {
        case "parent_changed": throw MutationParentError.replaced(parentID)
        case "scope_changed", "tree_scope_changed": throw SMBClientError.scopeChanged
        case "auth_required", "session_expired", "guest_refused": throw SMBClientError.authenticationRequired
        case "connection_lost", "timed_out", "transport_io": throw SMBClientError.serverUnreachable
        case "cancelled": throw CancellationError()
        case "disk_full": throw SMBClientError.diskFull
        case "directory_not_empty": throw NSFileProviderError(.directoryNotEmpty)
        case "not_found": throw ProviderErrors.noSuchItem()
        case "unsupported": throw MutationInput.unsupported("This NAS item uses a file feature that MyDrive cannot change safely yet.")
        case "access_denied": throw CocoaError(.fileWriteNoPermission)
        default:
            if result.outcome == .uncertain {
                if ["allocation_unknown", "unverified_stage", "delete_state_unknown"].contains(result.code) {
                    throw MutationInput.unsupported("The NAS operation needs recovery. Its local contents and recovery records are preserved.")
                }
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "The NAS result could not yet be verified. Local changes are preserved for retry."])
            }
            if result.outcome == .conflict { throw NSFileProviderError(.filenameCollision) }
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func requirePermanentDeletion(_ plan: MutationPlan) throws {
        let remaining = (plan.steps.map(\.request) + plan.retainedRequests).flatMap {
            [$0.receipt.staged, $0.receipt.archived].compactMap { $0 }
        }.filter { !plan.cleanedArtifacts.contains($0.path) }
        if remaining.contains(where: { !$0.cleanup_safe }) {
            throw MutationInput.unsupported("The NAS retained the deleted item for recovery. Its permanent deletion could not be verified.")
        }
        if !remaining.isEmpty {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                "The NAS item was removed from its folder, but permanent cleanup is still pending."])
        }
    }

    private func completedItem(_ result: MutationCommitResult, id: String) throws -> CatalogItem {
        guard let item = result.items.first(where: { $0.id == id }) else { throw SMBClientError.invalidResponse }
        return item
    }

    func deletionRejected(id: String, parentID: String, entry: RemoteEntry, message: String? = nil) async throws -> NSError {
        let item = CatalogItem(id: id, parentID: parentID, entry: entry)
        let projected = try await ProviderItemProjection.item(item, catalog: catalog, displayName: entry.name)
        let rejection = NSError.fileProviderErrorForRejectedDeletion(of: projected)
        guard let message else { return rejection }
        var info = rejection.userInfo
        info[NSLocalizedDescriptionKey] = message
        return NSError(domain: rejection.domain, code: rejection.code, userInfo: info)
    }

    /// Retried after commit and on OS callback replay; failures keep their exact
    /// receipt. Existing refresh can run the same bounded maintenance pass.
    func cleanup(plan: inout MutationPlan, retirePlan: Bool = true) async {
        if plan.treeImport != nil {
            await ProviderTreeImport(mutations: self).cleanPublished(&plan)
            return
        }
        var mayRetirePlan = retirePlan
        do {
            if let owner = try await catalog.treeImportOwner(operationKey: plan.key) {
                guard owner.key != plan.key, owner.layoutVersion == 2, owner.phase != .published else { return }
                try await ProviderTreeImport(mutations: self).qualifyChildCleanup(plan, status: owner)
                // Keep wire receipts until the root has passed its complete
                // publication gate. Missing files are not cleanup evidence.
                mayRetirePlan = false
            } else if let operation = try await catalog.operation(key: plan.key) {
                try plan.qualifySave(operation.intent, staging: staging)
                if operation.intent.saveContract != nil {
                    guard operation.state == .completed,
                          let completed = try await catalog.mutationResult(key: plan.key),
                          plan.steps.first?.result?.content_evidence == completed.contentEvidence else { return }
                }
            } else if (plan.steps.map(\.request) + plan.retainedRequests).contains(where: { $0.save_contract != nil }) { return }
        } catch { return }
        for (originalRequest, artifact) in plan.cleanupCandidates
                where artifact.cleanup_safe && !plan.cleanedArtifacts.contains(artifact.path) {
            do {
                try await checkActive()
                guard let operationID = UUID(uuidString: originalRequest.operation_id) else { continue }
                let request = SMBMutationRequest(operationID: operationID,
                    kind: .cleanup, path: artifact.path, parent: originalRequest.parent, expected: artifact.entry,
                    deleteScope: originalRequest.delete_scope, treeScope: originalRequest.tree_scope)
                let result = try await remote.mutate(request, false, nil)
                if result.outcome == .committed {
                    plan.cleanedArtifacts.insert(artifact.path)
                    try staging.save(plan)
                }
            } catch { return /* A later refresh/replay resumes this exact candidate. */ }
        }
        let artifacts = plan.cleanupCandidates.map(\.artifact)
        if mayRetirePlan && plan.localRecovery == nil && plan.unresolvedAllocationPaths.isEmpty && artifacts.allSatisfy({ plan.cleanedArtifacts.contains($0.path) }) {
            try? staging.removePlan(plan.key)
        }
    }

    func maintain(limit: Int = 8, after: UUID? = nil) async -> MutationMaintenanceReport {
        var report = MutationMaintenanceReport()
        for key in staging.planKeys(limit: limit, after: after) {
            report.nextCursor = key
            report.scannedOperations += 1
            do {
                try await checkActive()
                guard var plan = try staging.load(key) else { continue }
                report.retained += plan.unresolvedAllocationPaths.count
                if try await catalog.mutationResult(key: key) != nil {
                    await cleanup(plan: &plan)
                    if plan.treeImport != nil, (try? staging.load(key)) != nil { report.cleanupPending += 1 }
                    let artifacts = plan.cleanupCandidates.map(\.artifact).filter { !plan.cleanedArtifacts.contains($0.path) }
                    report.cleanupPending += artifacts.filter(\.cleanup_safe).count
                    report.retained += artifacts.filter { !$0.cleanup_safe }.count
                } else { report.recoveryPending += 1 }
            } catch { report.recoveryPending += 1 }
        }
        return report
    }

    static func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

    static func conflictName(_ name: String, key: UUID) -> String {
        let suffix = " (conflict \(key.uuidString.lowercased().prefix(12)))"
        let dot = name.lastIndex(of: ".")
        let hasExtension = dot != nil && dot != name.startIndex
        let rawExtension = hasExtension ? String(name[name.index(after: dot!)...]) : ""
        let stem = hasExtension ? String(name[..<dot!]) : name
        let ext = bounded(rawExtension, bytes: min(64, 255 - suffix.utf8.count - 2))
        let ending = ext.isEmpty ? "" : "." + ext
        return bounded(stem, bytes: 255 - suffix.utf8.count - ending.utf8.count) + suffix + ending
    }

    private static func bounded(_ value: String, bytes: Int) -> String {
        var result = ""
        for character in value {
            if result.utf8.count + String(character).utf8.count > bytes { break }
            result.append(character)
        }
        return result
    }
}

struct MutationMaintenanceReport: Sendable {
    var nextCursor: UUID?
    var scannedOperations = 0
    var cleanupPending = 0
    var retained = 0
    var recoveryPending = 0
}
