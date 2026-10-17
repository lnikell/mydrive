import Foundation
import MyDriveCore

extension ProviderTreeImport {
    func performMutation(step: TreeImportStep, intent: JournalIntent, parent: RemoteObjectIdentity,
                         destinationParent: RemoteObjectIdentity?, status: TreeImportStatus,
                         snapshot: LocalTreeSnapshot, progress: TreeWorkProgress) async throws -> TreeImportStatus {
        let requestedKey = intent.idempotencyKey
        var plan = try mutations.staging.load(requestedKey)
        if plan == nil {
            let request = try await request(for: step, intent: intent, parent: parent,
                destinationParent: destinationParent, status: status, snapshot: snapshot)
            plan = MutationPlan(key: requestedKey, itemID: intent.itemID,
                parentID: status.parentID, filename: status.filename,
                steps: [.init(request: request)], preservedOriginal: nil)
            try mutations.staging.save(plan!)
        }
        var operation = try await mutations.catalog.enqueueTreeImportChild(key: status.key, step: step, intent: intent)
        let key = operation.intent.idempotencyKey
        if key != requestedKey {
            try? mutations.staging.removePlan(requestedKey)
            plan = try mutations.staging.load(key)
        }
        guard var durable = plan else { throw CocoaError(.fileReadCorruptFile) }
        try qualify(durable, step: step, intent: operation.intent, parent: parent,
                    destinationParent: destinationParent, status: status, snapshot: snapshot)
        let recovering = operation.state != .queued
        if operation.state == .failed {
            operation = try await mutations.catalog.transitionOperation(key: key, from: .failed, to: .queued)
        }
        if operation.state == .queued {
            _ = try await mutations.catalog.transitionOperation(key: key, from: .queued, to: .executing)
        }
        do {
            try await mutations.performStep(0, plan: &durable, recovering: recovering, progress: progress.received)
            try mutations.requireCommitted(durable.steps[0], deleting: false, parentID: status.parentID)
            guard let result = durable.steps[0].result, let entry = result.entry else { throw SMBClientError.invalidResponse }
            try await mutations.checkActive()
            let current = try await mutations.catalog.recordTreeImportProgress(key: status.key,
                update: .committed(step: step, key: key, entry: entry.observation, sha256: result.sha256))
            await mutations.cleanup(plan: &durable, retirePlan: false)
            return current
        } catch {
            if let latest = try? await mutations.catalog.operation(key: key), latest.state == .executing {
                _ = try? await mutations.catalog.transitionOperation(key: key, from: .executing, to: .uncertain)
            }
            throw error
        }
    }

    private func request(for step: TreeImportStep, intent: JournalIntent, parent: RemoteObjectIdentity,
                         destinationParent: RemoteObjectIdentity?, status: TreeImportStatus,
                         snapshot: LocalTreeSnapshot) async throws -> SMBMutationRequest {
        let scope = step == .arena ? nil : try treeScope(status)
        switch intent.action {
        case .create(_, _, let kind):
            guard let target = intent.destinationPath else { throw CocoaError(.fileReadCorruptFile) }
            return SMBMutationRequest(operationID: intent.idempotencyKey,
                kind: kind == .directory ? .createDirectory : .createFile,
                path: target, parent: .init(parent),
                payload: intent.payload.map { .init(source: snapshot.payloadURL($0).path, bytes: $0.size, sha256: $0.sha256) },
                treeScope: scope)
        case .move:
            guard let source = intent.sourcePath, let target = intent.destinationPath, let scope,
                  let destinationParent, let observed = try await mutations.remote.treeStat(source, scope),
                  Self.matches(observed, base: intent.baseEntry) else {
                throw MutationInput.unsupported("The private folder import changed before publication. Its local snapshot and recovery records are preserved.")
            }
            try MutationPreparation.requireOrdinary(observed)
            return SMBMutationRequest(operationID: intent.idempotencyKey, kind: .move,
                path: source, parent: .init(parent), destination: target,
                destinationParent: .init(destinationParent), expected: observed, treeScope: scope)
        default: throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// Replays cannot replace a frozen arena/parent/path with current Catalog
    /// metadata. Rotation may change only the upload operation UUID/receipts.
    func qualify(_ plan: MutationPlan, step: TreeImportStep, intent: JournalIntent,
                         parent: RemoteObjectIdentity, destinationParent: RemoteObjectIdentity?,
                         status: TreeImportStatus, snapshot: LocalTreeSnapshot) throws {
        guard plan.key == intent.idempotencyKey, plan.itemID == intent.itemID, plan.steps.count == 1,
              plan.localRecovery == nil, plan.treeImport == nil,
              let target = intent.destinationPath else { throw CocoaError(.fileReadCorruptFile) }
        let request = plan.steps[0].request
        guard request.parent == .init(parent), request.delete_scope == nil,
              request.tree_scope == (step == .arena ? nil : try treeScope(status)) else { throw CocoaError(.fileReadCorruptFile) }
        switch intent.action {
        case .create(_, _, let kind):
            guard request.kind == (kind == .directory ? .createDirectory : .createFile),
                  request.path.utf8.elementsEqual(target.utf8), request.destination == nil,
                  request.expected == nil, request.payload?.bytes == intent.payload?.size,
                  request.payload?.sha256 == intent.payload?.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            if let payload = intent.payload {
                guard request.payload?.source.utf8.elementsEqual(snapshot.payloadURL(payload).path.utf8) == true else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        case .move:
            guard request.kind == .move, let source = intent.sourcePath,
                  request.path.utf8.elementsEqual(source.utf8), request.destination?.utf8.elementsEqual(target.utf8) == true,
                  request.destination_parent == destinationParent.map(SMBMutationRequest.ParentIdentity.init),
                  Self.matches(request.expected, base: intent.baseEntry), request.payload == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        default: throw CocoaError(.fileReadCorruptFile)
        }
    }

    static func matches(_ entry: SMBEntry?, base: RemoteEntry?) -> Bool {
        guard let entry, let base else { return false }
        let observed = entry.observation
        return observed.name.utf8.elementsEqual(base.name.utf8) && observed.kind == base.kind &&
            observed.objectIdentity == base.objectIdentity && observed.size == base.size &&
            observed.contentVersion.utf8.elementsEqual(base.contentVersion.utf8) &&
            observed.metadataVersion.utf8.elementsEqual(base.metadataVersion.utf8)
    }
}
