import Foundation
import MyDriveCore

/// External I/O seam. Every invocation obtains a fresh operation client, so an
/// expired credential cannot survive inside a retained mutation worker.
struct MutationRemote: Sendable {
    var stat: @Sendable (String) async throws -> SMBEntry?
    var scopedStat: @Sendable (String, SMBDeleteScope) async throws -> SMBEntry?
    var scopedList: @Sendable (String, SMBDeleteScope, @escaping @Sendable ([RemoteEntry]) async throws -> Void) async throws -> SMBEntry
    var treeStat: @Sendable (String, SMBTreeScope) async throws -> SMBEntry?
    var treeList: @Sendable (String, SMBTreeScope, @escaping @Sendable ([RemoteEntry]) async throws -> Void) async throws -> SMBEntry
    var treeRead: @Sendable (String, URL, SMBTreeScope, @escaping @Sendable (Int64) -> Void) async throws -> RemoteEntry
    var mutate: @Sendable (SMBMutationRequest, Bool, (@Sendable (Int64) -> Void)?) async throws -> SMBMutationResult

    init(client: @escaping @Sendable () async throws -> SMBClient) {
        stat = { path in try await client().stat(path: path) }
        scopedStat = { path, scope in try await client().stat(path: path, deleteScope: scope) }
        scopedList = { path, scope, page in try await client().listDirectory(path: path, deleteScope: scope, onPage: page) }
        treeStat = { path, scope in try await client().stat(path: path, treeScope: scope) }
        treeList = { path, scope, page in try await client().listDirectory(path: path, treeScope: scope, onPage: page) }
        treeRead = { path, destination, scope, progress in try await client().download(path: path, to: destination, treeScope: scope, progress: progress) }
        mutate = { request, reconcile, progress in
            try await client().mutate(request, reconcile: reconcile, progress: progress)
        }
    }

    init(stat: @escaping @Sendable (String) async throws -> SMBEntry?,
         mutate: @escaping @Sendable (SMBMutationRequest, Bool, (@Sendable (Int64) -> Void)?) async throws -> SMBMutationResult,
         scopedStat: @escaping @Sendable (String, SMBDeleteScope) async throws -> SMBEntry? = { _, _ in throw SMBClientError.unsupportedFeature },
         scopedList: @escaping @Sendable (String, SMBDeleteScope, @escaping @Sendable ([RemoteEntry]) async throws -> Void) async throws -> SMBEntry = { _, _, _ in throw SMBClientError.unsupportedFeature },
         treeStat: @escaping @Sendable (String, SMBTreeScope) async throws -> SMBEntry? = { _, _ in throw SMBClientError.unsupportedFeature },
         treeList: @escaping @Sendable (String, SMBTreeScope, @escaping @Sendable ([RemoteEntry]) async throws -> Void) async throws -> SMBEntry = { _, _, _ in throw SMBClientError.unsupportedFeature },
         treeRead: @escaping @Sendable (String, URL, SMBTreeScope, @escaping @Sendable (Int64) -> Void) async throws -> RemoteEntry = { _, _, _, _ in throw SMBClientError.unsupportedFeature }) {
        self.stat = stat; self.mutate = mutate
        self.scopedStat = scopedStat; self.scopedList = scopedList
        self.treeStat = treeStat; self.treeList = treeList; self.treeRead = treeRead
    }
}

