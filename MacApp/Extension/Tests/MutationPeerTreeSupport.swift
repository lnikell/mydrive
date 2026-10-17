import Foundation
import MyDriveCore

extension MutationPeer {
    func networkStat(_ path: String) throws -> SMBEntry? {
        if statOffline { throw SMBClientError.serverUnreachable }
        return stat(path)
    }
    func setStatOffline(_ value: Bool) { statOffline = value }

    func treeFence(_ scope: SMBTreeScope, allowAbsentArena: Bool = false) -> Bool {
        guard scope.isValid else { return false }
        let parentPath = scope.arena_path.split(separator: "/").dropLast().joined(separator: "/")
        guard let parent = stat(parentPath), parent.objectIdentity.map(SMBMutationRequest.ParentIdentity.init) == scope.parent else { return false }
        guard let arena = stat(scope.arena_path) else { return allowAbsentArena }
        return arena.directory && arena.objectIdentity.map(SMBMutationRequest.ParentIdentity.init) == scope.arena
    }

    func treeStat(_ path: String, _ scope: SMBTreeScope) throws -> SMBEntry? {
        guard scope.contains(path), treeFence(scope, allowAbsentArena: path == scope.arena_path) else { throw SMBClientError.scopeChanged }
        return stat(path)
    }

    func treeList(_ path: String, _ scope: SMBTreeScope,
                  page: @escaping @Sendable ([RemoteEntry]) async throws -> Void) async throws -> SMBEntry {
        guard treeFence(scope), let directory = stat(path), directory.directory else { throw SMBClientError.scopeChanged }
        let children = entries.filter { $0.key.split(separator: "/").dropLast().joined(separator: "/").utf8.elementsEqual(path.utf8) }
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }.map { $0.value.observation }
        for offset in stride(from: 0, to: children.count, by: 7) {
            try await page(Array(children[offset..<min(offset + 7, children.count)]))
        }
        return directory
    }

    func treeRead(_ path: String, _ destination: URL, _ scope: SMBTreeScope) throws -> RemoteEntry {
        guard treeFence(scope), let entry = stat(path), !entry.directory, let bytes = contents[path] else { throw SMBClientError.scopeChanged }
        try (corruptTreeRead ? Data("corrupt readback".utf8) : bytes).write(to: destination, options: .withoutOverwriting)
        return entry.observation
    }

    func setTreeReadCorrupt(_ value: Bool) { corruptTreeRead = value }
    func loseTreePublication(to path: String) { loseMoveTarget = path }
    func cancelTreePlacement(_ latch: CancellationLatch) { cancelAfterTreePlacement = latch }

    func treePaths() -> [String] { entries.keys.sorted() }
}
