import CryptoKit
import FileProvider
import Foundation
import MyDriveCore
import UniformTypeIdentifiers
import Darwin

struct MutationTestFailure: Error { let message: String }
func mutationCheck(_ condition: Bool, _ message: String) throws {
    if !condition { throw MutationTestFailure(message: message) }
}

final class WriteTemplate: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    init(id: String, parent: String = Catalog.rootID, name: String, directory: Bool = false) {
        itemIdentifier = ProviderItem.identifier(id); parentItemIdentifier = ProviderItem.identifier(parent)
        filename = name; contentType = directory ? .folder : .plainText
    }
}

actor CancellationLatch {
    var cancelled = false
    func set(_ value: Bool) { cancelled = value }
    func check() throws { if cancelled { throw CancellationError() } }
}

/// A protocol peer with receipts and adversarial lost replies. It stores no
/// credentials and never starts SMB or a registered File Provider domain.
actor MutationPeer {
    static let rootEntry = SMBEntry(name: "", bytes: 0, directory: true, index_number: 1,
        created_filetime: 1, modified_filetime: 1, changed_filetime: 1, attributes: 0x10)
    private var rootOverride: SMBEntry?
    var entries: [String: SMBEntry] = [:]
    var hashes: [String: String] = [:]
    var contents: [String: Data] = [:]
    private var nextIndex: UInt64 = 10
    private(set) var stagedCount = 0
    private(set) var publishedCount = 0
    private(set) var calls = 0
    private(set) var mutationRequests: [SMBMutationRequest] = []
    private(set) var reconciliationRoles: [Bool] = []
    var cancelAfterPublished: CancellationLatch?
    var loseNextPublishedReply = false
    var cancelAfterPrepared: CancellationLatch?
    var removeAfterPublish: String?
    var failCleanups = 0
    var unsafeArchive = false
    private var replaceParentAfterPrepared = false
    private var replaceParentAfterConflict = false
    private var allocatedMode = false
    private var interruptAllocatedWrite = false
    private var lostAllocationReplies = 0
    private var nextFailureCode: String?
    var loseMoveTarget: String?
    var corruptTreeRead = false
    var cancelAfterTreePlacement: CancellationLatch?
    var statOffline = false
    private(set) var cleanupCalls = 0

    func removeOldPathAfterPublish(_ path: String) { removeAfterPublish = path }
    func failNextCleanup() { failCleanups = 1 }
    func markArchiveUnsafe() { unsafeArchive = true }
    func replaceParentAfterStage() { replaceParentAfterPrepared = true }
    func replaceParentOnFileConflict() { replaceParentAfterConflict = true }
    func useAllocatedReceipts(interruptWrite: Bool = false, lostReplies: Int = 0) {
        allocatedMode = true; interruptAllocatedWrite = interruptWrite; lostAllocationReplies = lostReplies
    }
    func loseReply() { loseNextPublishedReply = true }
    func cancelAfterPublication(_ latch: CancellationLatch) { cancelAfterPublished = latch }
    func failNextMutation(code: String) { nextFailureCode = code }
    func cancelAfterStage(_ latch: CancellationLatch?) { cancelAfterPrepared = latch }
    func stat(_ path: String) -> SMBEntry? { path.isEmpty ? rootOverride ?? Self.rootEntry : entries[path] }
    func replaceRoot() {
        rootOverride = SMBEntry(name: "", bytes: 0, directory: true, index_number: 999,
            created_filetime: 999, modified_filetime: 1, changed_filetime: 1, attributes: 0x10)
    }
    func hash(_ path: String) -> String? { hashes[path] }
    func remove(_ path: String) { entries.removeValue(forKey: path); hashes.removeValue(forKey: path); contents.removeValue(forKey: path) }
    func counts() -> (Int, Int, Int) { (stagedCount, publishedCount, calls) }

    func seed(path: String, bytes: Data, directory: Bool = false) -> SMBEntry {
        nextIndex += 1
        let entry = SMBEntry(name: path.split(separator: "/").last.map(String.init)!, bytes: Int64(bytes.count),
            directory: directory, index_number: nextIndex, created_filetime: 100 + nextIndex,
            modified_filetime: 200 + nextIndex, changed_filetime: 300 + nextIndex,
            attributes: directory ? 0x10 : 0x20)
        entries[path] = entry; hashes[path] = Self.hash(bytes); contents[path] = bytes
        return entry
    }

    func mutate(_ request: SMBMutationRequest, _ reconcile: Bool,
                _ progress: (@Sendable (Int64) -> Void)?) async throws -> SMBMutationResult {
        calls += 1
        mutationRequests.append(request)
        reconciliationRoles.append(reconcile)
        var receipt = request.receipt
        func result(_ outcome: SMBMutationResult.Outcome, _ code: String,
                    entry: SMBEntry? = nil, hash: String? = nil) -> SMBMutationResult {
            SMBMutationResult(operation_id: request.operation_id, outcome: outcome, code: code,
                              entry: entry, sha256: request.save_contract == nil ? hash : nil,
                              cleanup_pending: receipt.staged != nil || receipt.archived != nil, receipt: receipt,
                              saveContract: request.save_contract,
                              contentEvidence: request.save_contract != nil && outcome == .committed ? request.payload.map {
                                  .init(kind: reconcile ? .remoteSHA256 : .smbAcknowledged, bytes: $0.bytes, sha256: $0.sha256)
                              } : nil)
        }
        if let code = nextFailureCode { nextFailureCode = nil; return result(.notApplied, code) }
        func parentMatches(_ path: String, _ identity: SMBMutationRequest.ParentIdentity?) -> Bool {
            let parentPath = path.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
            guard let parent = stat(parentPath), parent.directory, let observed = parent.objectIdentity else { return false }
            return identity == .init(observed)
        }
        guard parentMatches(request.path, request.parent),
              request.kind != .move || parentMatches(request.destination!, request.destination_parent) else {
            return result(.conflict, "parent_changed")
        }
        if let scope = request.tree_scope, !treeFence(scope, allowAbsentArena:
            (request.kind == .delete || request.kind == .move) && request.path.utf8.elementsEqual(scope.arena_path.utf8)) {
            return result(.conflict, "tree_scope_changed")
        }
        switch request.kind {
        case .createFile, .createDirectory, .replaceFile:
            let allocates = (allocatedMode || request.save_contract != nil) && request.kind != .createDirectory
            if request.kind == .replaceFile && replaceParentAfterConflict {
                _ = seed(path: request.path, bytes: Data("concurrent external edit".utf8))
                replaceParentAfterConflict = false
                replaceRoot()
                return result(.conflict, "changed")
            }
            if let current = entries[request.path], current.index_number == receipt.staged?.entry.index_number {
                if request.save_contract != nil {
                    guard reconcile else { return result(.uncertain, "reconcile_required") }
                    guard current.objectIdentity == receipt.staged?.entry.objectIdentity,
                          current.bytes == request.payload?.bytes, hashes[request.path] == request.payload?.sha256 else {
                        return result(.uncertain, "changed")
                    }
                }
                receipt.staged = nil
                return result(.committed, "committed", entry: current, hash: request.payload?.sha256)
            }
            if let current = entries[request.path], request.kind != .replaceFile || current != request.expected {
                return result(.conflict, "changed")
            }
            if allocates, receipt.staged == nil, entries[request.sidecar("stage")] != nil {
                return result(.uncertain, "allocation_unknown")
            }
            if reconcile {
                if receipt.staged?.phase == .allocated { return result(.notApplied, "allocated") }
                return result(.notApplied, "not_applied")
            }
            if receipt.staged == nil {
                let bytes = try request.payload.map { try Data(contentsOf: URL(fileURLWithPath: $0.source)) } ?? Data()
                let path = request.sidecar("stage")
                let entry = seed(path: path, bytes: allocates ? Data() : bytes, directory: request.kind == .createDirectory)
                receipt.staged = .init(path: path, entry: entry, cleanup_safe: true,
                    phase: allocates ? .allocated : .prepared,
                    security_sha256: allocates ? String(repeating: "a", count: 64) : nil, saveContract: request.save_contract)
                stagedCount += 1
                if allocates, lostAllocationReplies > 0 { lostAllocationReplies -= 1; throw SMBClientError.serverUnreachable }
                if !allocates { progress?(Int64(bytes.count)) }
                if let latch = cancelAfterPrepared { await latch.set(true) }
                if replaceParentAfterPrepared { replaceParentAfterPrepared = false; replaceRoot() }
                return result(.notApplied, allocates ? "allocated" : "prepared")
            }
            guard let stage = receipt.staged, var staged = entries[stage.path] else {
                return result(.uncertain, "unverified_stage")
            }
            if stage.phase == .allocated {
                let bytes = try request.payload.map { try Data(contentsOf: URL(fileURLWithPath: $0.source)) } ?? Data()
                let interrupted = interruptAllocatedWrite
                interruptAllocatedWrite = false
                let written = interrupted ? Data(bytes.prefix(max(1, bytes.count / 2))) : bytes
                let entry = SMBEntry(name: staged.name, bytes: Int64(written.count), directory: staged.directory,
                    index_number: staged.index_number, created_filetime: staged.created_filetime,
                    modified_filetime: staged.modified_filetime + 1, changed_filetime: staged.changed_filetime + 1,
                    attributes: staged.attributes)
                entries[stage.path] = entry; hashes[stage.path] = Self.hash(written); contents[stage.path] = written
                progress?(Int64(written.count))
                if interrupted { throw SMBClientError.serverUnreachable }
                if request.save_contract == nil {
                    receipt.staged = .init(path: stage.path, entry: entry, cleanup_safe: true,
                        phase: .prepared, security_sha256: stage.security_sha256)
                    return result(.notApplied, "prepared")
                }
                staged = entry
            }
            if request.kind == .replaceFile, let original = entries[request.path] {
                let path = request.sidecar("backup")
                let archived = move(request.path, to: path, entry: original)
                receipt.archived = .init(path: path, entry: archived, cleanup_safe: !unsafeArchive)
            }
            let final = move(stage.path, to: request.path, entry: staged)
            receipt.staged = nil; publishedCount += 1
            if let latch = cancelAfterPublished { cancelAfterPublished = nil; await latch.set(true) }
            if let path = removeAfterPublish { entries.removeValue(forKey: path); hashes.removeValue(forKey: path); removeAfterPublish = nil }
            if loseNextPublishedReply {
                loseNextPublishedReply = false
                throw SMBClientError.serverUnreachable
            }
            return result(.committed, "committed", entry: final, hash: request.payload?.sha256)
        case .move:
            let target = request.destination!
            if entries[request.path] == nil, let current = entries[target], current.index_number == request.expected?.index_number {
                return result(.committed, "committed", entry: current)
            }
            guard entries[target] == nil, let original = entries[request.path], original == request.expected else {
                return result(.conflict, "changed")
            }
            if reconcile { return result(.notApplied, "not_applied") }
            let final = move(request.path, to: target, entry: original)
            publishedCount += 1
            if let latch = cancelAfterTreePlacement, request.tree_scope != nil {
                cancelAfterTreePlacement = nil; await latch.set(true)
            }
            if loseMoveTarget == target { loseMoveTarget = nil; throw SMBClientError.serverUnreachable }
            if loseNextPublishedReply { loseNextPublishedReply = false; throw SMBClientError.serverUnreachable }
            return result(.committed, "committed", entry: final)
        case .delete:
            let archivedPath = request.sidecar("deleted")
            if entries[request.path] == nil, let original = entries[archivedPath],
               original.index_number == request.expected?.index_number {
                receipt.archived = .init(path: archivedPath, entry: original,
                                         cleanup_safe: request.receipt.archived?.cleanup_safe ?? false)
                return result(.committed, "committed")
            }
            guard let original = entries[request.path], original == request.expected else {
                return result(.conflict, "changed")
            }
            if original.directory && entries.keys.contains(where: { $0.hasPrefix(request.path + "/") }) {
                return result(.notApplied, "directory_not_empty")
            }
            if reconcile { return result(.notApplied, "not_applied") }
            if original.directory { remove(request.path) }
            else {
                let archived = move(request.path, to: archivedPath, entry: original)
                receipt.archived = .init(path: archivedPath, entry: archived, cleanup_safe: !unsafeArchive)
            }
            publishedCount += 1
            return result(.committed, "committed")
        case .cleanup:
            cleanupCalls += 1
            if failCleanups > 0 { failCleanups -= 1; throw SMBClientError.serverUnreachable }
            if let current = entries[request.path], current != request.expected { return result(.conflict, "changed") }
            remove(request.path)
            return result(.committed, "committed")
        }
    }

    private func move(_ source: String, to target: String, entry: SMBEntry) -> SMBEntry {
        entries.removeValue(forKey: source)
        let hash = hashes.removeValue(forKey: source)
        let bytes = contents.removeValue(forKey: source)
        if entry.directory {
            for path in Array(entries.keys).filter({ $0.utf8.starts(with: (source + "/").utf8) }) {
                let destination = target + path.dropFirst(source.count)
                entries[destination] = entries.removeValue(forKey: path)
                hashes[destination] = hashes.removeValue(forKey: path)
                contents[destination] = contents.removeValue(forKey: path)
            }
        }
        let renamed = SMBEntry(name: target.split(separator: "/").last.map(String.init)!, bytes: entry.bytes,
            directory: entry.directory, index_number: entry.index_number, created_filetime: entry.created_filetime,
            modified_filetime: entry.modified_filetime, changed_filetime: entry.changed_filetime + 1,
            attributes: entry.attributes)
        entries[target] = renamed; hashes[target] = hash; contents[target] = bytes
        return renamed
    }

    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

