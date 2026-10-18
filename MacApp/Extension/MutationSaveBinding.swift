import Foundation
import MyDriveCore

extension MutationPlan {
    /// Qualify a loaded ordinary upload against its canonical intent before an
    /// RPC. Tree children have their existing manifest-specific qualifier.
    func qualifySave(_ intent: JournalIntent, staging: MutationStaging) throws {
        guard key == intent.idempotencyKey, itemID == intent.itemID else { throw corruptSave() }
        let requests = steps.map(\.request) + retainedRequests
        for request in requests {
            try request.validate(receipt: request.receipt)
            guard request.save_contract == (request.payload == nil ? nil : intent.saveContract) else { throw corruptSave() }
        }
        for step in steps { try step.result?.validate(for: step.request) }
        guard intent.saveContract != nil else { return }
        guard let payload = intent.payload, let target = intent.destinationPath,
              (1...2).contains(steps.count), localRecovery == nil, treeImport == nil else { throw corruptSave() }
        let parent: String
        switch intent.action {
        case .create(let id, _, .file), .update(let id, _): parent = id
        default: throw corruptSave()
        }
        guard parentID == parent else { throw corruptSave() }
        let targetParts = target.split(separator: "/", omittingEmptySubsequences: false)
        guard let name = targetParts.last else { throw corruptSave() }
        var targets = [target], conflictName = String(name)
        for _ in 0...retainedRequests.count {
            conflictName = ProviderMutations.conflictName(conflictName, key: key)
            targets.append(ProviderMutations.join(targetParts.dropLast().joined(separator: "/"), conflictName))
        }
        var ids = Set<String>()
        for start in [key, MutationInput.derivedID(key, "conflict")] {
            var id = start
            for _ in 0...2 {
                ids.insert(id.uuidString.lowercased())
                id = MutationInput.derivedID(id, "allocation-retry")
            }
        }
        for request in requests {
            guard request.tree_scope == nil, request.delete_scope == nil else { throw corruptSave() }
            if let body = request.payload {
                guard [.createFile, .replaceFile].contains(request.kind), ids.contains(request.operation_id),
                      body.bytes == payload.size, body.sha256 == payload.sha256,
                      body.source.utf8.elementsEqual(staging.payloadURL(payload.id).path.utf8),
                      targets.contains(where: { $0.utf8.elementsEqual(request.path.utf8) }),
                      request.destination == nil, request.destination_parent == nil else { throw corruptSave() }
                if request.kind == .replaceFile {
                    guard intent.sourcePath?.utf8.elementsEqual(request.path.utf8) == true,
                          target.utf8.elementsEqual(request.path.utf8), matchesBase(request.expected, intent) else { throw corruptSave() }
                } else if request.expected != nil { throw corruptSave() }
            } else {
                guard request.kind == .delete,
                      request.operation_id == MutationInput.derivedID(key, "retire-original").uuidString.lowercased(),
                      intent.sourcePath?.utf8.elementsEqual(request.path.utf8) == true,
                      request.destination == nil, matchesBase(request.expected, intent) else { throw corruptSave() }
            }
        }
        guard steps[0].request.payload != nil,
              steps[0].request.path.split(separator: "/").last?.utf8.elementsEqual(filename.utf8) == true,
              steps.count == 1 || (steps[0].request.kind == .createFile && steps[1].request.kind == .delete) else { throw corruptSave() }
    }

    /// The terminal receipt truthfully clears stage. Keep its original creator
    /// binding in the saved request until Core commits or strict replay adopts
    /// the target; this is not an assertion that the stage path still exists.
    mutating func recordSaveResult(_ result: SMBMutationResult, at index: Int) {
        let original = steps[index].request.receipt.staged
        steps[index].result = result
        steps[index].request.receipt = result.receipt
        if steps[index].request.save_contract != nil, result.receipt.staged == nil {
            steps[index].request.receipt.staged = original
        }
    }

    /// A committed V2 result retires its stage namespace. The saved request
    /// still retains creator history for pre-Core recovery, not an extra live
    /// cleanup candidate. Callers qualify canonical completion before cleanup.
    var cleanupCandidates: [(request: SMBMutationRequest, artifact: SMBMutationRequest.Artifact)] {
        let active = steps.map { step -> SMBMutationRequest in
            var request = step.request
            if request.save_contract != nil, let result = step.result, result.outcome == .committed {
                request.receipt = result.receipt
            }
            return request
        } + retainedRequests
        return active.flatMap { request in
            [request.receipt.staged, request.receipt.archived].compactMap { artifact in
                artifact.map { (request, $0) }
            }
        }
    }

    private func matchesBase(_ entry: SMBEntry?, _ intent: JournalIntent) -> Bool {
        guard let entry, let content = intent.expectedVersion,
              entry.observation.contentVersion.utf8.elementsEqual(content.utf8),
              intent.expectedMetadataVersion.map({ entry.observation.metadataVersion.utf8.elementsEqual($0.utf8) }) ?? true else { return false }
        if let base = intent.baseEntry { return ProviderTreeImport.matches(entry, base: base) }
        return true
    }

    private func corruptSave() -> CocoaError { CocoaError(.fileReadCorruptFile) }
}
