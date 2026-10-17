import FileProvider
import Foundation
import MyDriveCore

enum MutationParentError: Error, Sendable {
    case refreshRequired(String), replaced(String)

    var parentID: String {
        switch self { case .refreshRequired(let id), .replaced(let id): return id }
    }
}

/// Resolve a new OS intent to guarded remote steps. All mutable observations
/// become immutable journal/transport records before the executor can write.
struct MutationPreparation: Sendable {
    let catalog: Catalog
    let staging: MutationStaging
    let remote: MutationRemote

    func prepare(_ input: MutationInput, create: Bool, key: UUID,
                         payload: StagedPayload?) async throws -> (intent: JournalIntent, plan: MutationPlan) {
        guard let parent = try await catalog.item(id: input.parentID), !parent.isDeleted,
              parent.entry.kind == .directory, let parentPath = try await catalog.relativePath(id: input.parentID) else {
            throw NSError.fileProviderErrorForNonExistentItem(withIdentifier: ProviderItem.identifier(input.parentID))
        }
        let target = ProviderMutations.join(parentPath, input.filename)
        let targetParent = try await verifiedParent(input.parentID)
        let wirePayload = payload.map { SMBMutationRequest.Payload(source: staging.payloadURL($0.id).path,
                                                                    bytes: $0.size, sha256: $0.sha256) }
        if create {
            let id = try await catalog.providerID(forCreateTemplate: input.id)
            if let existing = try await catalog.item(id: id), !existing.isDeleted {
                guard input.kind == .file, let wirePayload,
                      let oldParent = existing.parentID,
                      let source = try await catalog.relativePath(id: id),
                      let original = try await remote.stat(source) else {
                    throw MutationInput.unsupported("This imported item needs a refresh before its creation can be replayed safely.")
                }
                _ = try await verifiedParent(oldParent)
                let name = ProviderMutations.conflictName(input.filename, key: key)
                let request = SMBMutationRequest(operationID: key, kind: .createFile,
                    path: ProviderMutations.join(parentPath, name), parent: targetParent, payload: wirePayload)
                let intent = JournalIntent(idempotencyKey: key, itemID: id,
                    expectedVersion: existing.entry.contentVersion,
                    action: .update(parentID: input.parentID, name: name),
                    expectedMetadataVersion: existing.entry.metadataVersion, payload: payload,
                    createTemplateID: nil, sourcePath: source, destinationPath: request.path,
                    baseEntry: existing.entry)
                let originalID = try await catalog.providerID(forCreateTemplate: "conflict-original:\(key.uuidString.lowercased())")
                var plan = MutationPlan(key: key, itemID: id, parentID: input.parentID, filename: name,
                    steps: [.init(request: request)], preservedOriginal: CatalogMutationItem(
                        id: originalID, parentID: oldParent, entry: original.observation))
                plan.sourceParentID = oldParent
                return (intent, plan)
            }
            if try await remote.stat(target) != nil { throw try await collision(parentID: input.parentID, name: input.filename) }
            let request = SMBMutationRequest(operationID: key,
                kind: input.kind == .directory ? .createDirectory : .createFile, path: target, parent: targetParent, payload: wirePayload)
            let intent = JournalIntent(idempotencyKey: key, itemID: id, expectedVersion: nil,
                action: .create(parentID: input.parentID, name: input.filename, kind: input.kind),
                payload: payload, createTemplateID: input.id, destinationPath: target)
            return (intent, MutationPlan(key: key, itemID: id, parentID: input.parentID,
                filename: input.filename, steps: [.init(request: request)], preservedOriginal: nil))
        }
        guard input.id != Catalog.rootID, let item = try await catalog.item(id: input.id), !item.isDeleted,
              let oldParent = item.parentID, let source = try await catalog.relativePath(id: input.id) else { throw ProviderErrors.noSuchItem() }
        guard input.kind == item.entry.kind else { throw MutationInput.unsupported("Changing an item's file type is not supported.") }
        let sourceParent = oldParent == input.parentID ? targetParent : try await verifiedParent(oldParent)
        let observed = try await remote.stat(source)
        if observed == nil, let wirePayload {
            // A remote delete/rename does not authorize losing a dirty local
            // save. Recover it under the verified requested parent without
            // inventing or deleting a remote original.
            let name = ProviderMutations.conflictName(input.filename, key: key)
            let destination = ProviderMutations.join(parentPath, name)
            let request = SMBMutationRequest(operationID: key, kind: .createFile,
                path: destination, parent: targetParent, payload: wirePayload)
            let intent = JournalIntent(idempotencyKey: key, itemID: item.id,
                expectedVersion: item.entry.contentVersion, action: .update(parentID: input.parentID, name: name),
                expectedMetadataVersion: item.entry.metadataVersion, payload: payload,
                sourcePath: source, destinationPath: destination, baseEntry: item.entry)
            var plan = MutationPlan(key: key, itemID: item.id, parentID: input.parentID,
                filename: name, steps: [.init(request: request)], preservedOriginal: nil)
            plan.sourceParentID = oldParent
            return (intent, plan)
        }
        guard let observed else { throw ProviderErrors.noSuchItem() }
        try Self.requireOrdinary(observed)
        let observedMatches = Self.matches(observed, content: input.baseContent, metadata: input.baseMetadata)
        if target.utf8.starts(with: (source + "/").utf8) { throw MutationInput.unsupported("A folder cannot be moved inside itself.") }
        let action = JournalAction.update(parentID: input.parentID, name: input.filename)
        let intent = JournalIntent(idempotencyKey: key, itemID: item.id,
            expectedVersion: input.baseContent.flatMap { String(data: $0, encoding: .utf8) }, action: action,
            expectedMetadataVersion: input.baseMetadata.flatMap { String(data: $0, encoding: .utf8) }, payload: payload,
            sourcePath: source, destinationPath: target,
            baseEntry: input.baseContent == Data(item.entry.contentVersion.utf8) && input.baseMetadata == Data(item.entry.metadataVersion.utf8) ? item.entry : nil)
        var plan = MutationPlan(key: key, itemID: item.id, parentID: input.parentID,
                                filename: input.filename, steps: [], preservedOriginal: nil)
        plan.sourceParentID = oldParent
        if let wirePayload {
            if !observedMatches {
                plan.filename = ProviderMutations.conflictName(input.filename, key: key)
                let conflictPath = ProviderMutations.join(parentPath, plan.filename)
                plan.steps = [.init(request: SMBMutationRequest(operationID: key, kind: .createFile,
                                                                path: conflictPath, parent: targetParent, payload: wirePayload))]
                plan.preservedOriginal = CatalogMutationItem(
                    id: try await catalog.providerID(forCreateTemplate: "conflict-original:\(key.uuidString.lowercased())"),
                    parentID: oldParent, entry: observed.observation)
            } else if source.utf8.elementsEqual(target.utf8) {
                plan.steps = [.init(request: SMBMutationRequest(operationID: key, kind: .replaceFile,
                    path: source, parent: sourceParent, expected: observed, payload: wirePayload))]
            } else {
                if try await remote.stat(target) != nil { throw try await collision(parentID: input.parentID, name: input.filename) }
                plan.steps = [
                    .init(request: SMBMutationRequest(operationID: key, kind: .createFile, path: target, parent: targetParent, payload: wirePayload)),
                    .init(request: SMBMutationRequest(operationID: MutationInput.derivedID(key, "retire-original"),
                                                      kind: .delete, path: source, parent: sourceParent, expected: observed))]
            }
        } else {
            guard observedMatches else {
                throw MutationInput.unsupported("The NAS item changed before this rename or move. Refresh it before trying again.")
            }
            guard !source.utf8.elementsEqual(target.utf8) else { throw MutationInput.unsupported("This change has no supported remote fields.") }
            if let destination = try await remote.stat(target),
               !Self.sameIdentity(observed.observation, destination.observation) {
                throw try await collision(parentID: input.parentID, name: input.filename)
            }
            // On case-insensitive servers the destination may be an alias for
            // this same object. The backend verifies the stored spelling and
            // performs a guarded no-overwrite rename; different objects refuse.
            plan.steps = [.init(request: SMBMutationRequest(operationID: key, kind: .move,
                    path: source, parent: sourceParent, destination: target,
                    destinationParent: targetParent, expected: observed))]
        }
        return (intent, plan)
    }

    static func matches(_ entry: SMBEntry, content: Data?, metadata: Data?) -> Bool {
        content == Data(entry.observation.contentVersion.utf8) && metadata == Data(entry.observation.metadataVersion.utf8)
    }

    static func requireOrdinary(_ entry: SMBEntry) throws {
        guard entry.objectIdentity != nil,
              entry.attributes & 0x400 == 0 else {
            throw MutationInput.unsupported("This NAS item does not provide a safe identity for changes.")
        }
    }

    /// A synthetic root has no cached SMB identity. Every other parent must
    /// match a listing observation before its identity can enter a durable RPC.
    func verifiedParent(_ id: String) async throws -> SMBMutationRequest.ParentIdentity {
        guard let parent = try await catalog.item(id: id), !parent.isDeleted,
              parent.entry.kind == .directory, let path = try await catalog.relativePath(id: id) else {
            throw ProviderErrors.noSuchItem()
        }
        if id != Catalog.rootID, parent.entry.objectIdentity == nil { throw MutationParentError.refreshRequired(id) }
        guard let observed = try await remote.stat(path), observed.directory,
              observed.attributes & 0x400 == 0, let identity = observed.objectIdentity else {
            throw MutationParentError.replaced(id)
        }
        if id != Catalog.rootID, parent.entry.objectIdentity != identity { throw MutationParentError.replaced(id) }
        return .init(identity)
    }

    func collision(parentID: String, name: String) async throws -> NSError {
        if let item = try await catalog.child(named: name, in: parentID) {
            let value = ProviderItem(item, policy: try await catalog.offlinePolicy(for: item.id), displayName: name)
            return NSError.fileProviderErrorForCollision(with: value)
        }
        return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.filenameCollision.rawValue)
    }
    static func sameIdentity(_ left: RemoteEntry, _ right: RemoteEntry) -> Bool {
        guard left.kind == right.kind, let identity = left.objectIdentity,
              identity.indexNumber != 0, identity.createdFiletime != 0 else { return false }
        return identity == right.objectIdentity
    }
}
