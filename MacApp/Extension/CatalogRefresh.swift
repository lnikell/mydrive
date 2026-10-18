import FileProvider
import Foundation
import MyDriveCore

/// The change feed is durable, while Finder notifications can fail independently.
/// A new owner signals once, and a committed scan stays pending until delivery.
actor CatalogPublication {
    private var revision: UInt64 = 0
    private var pending = true

    func record(changed: Bool) {
        if changed {
            revision &+= 1
            pending = true
        }
    }

    func notify(_ publish: @Sendable () async throws -> Void) async throws {
        guard pending else { return }
        let observed = revision
        try await publish()
        // Do not consume a newer publication if its scan completed while the
        // notification was suspended. The domain gate normally serializes them.
        if revision == observed { pending = false }
    }
}

/// An exhaustive listing is the proof that both connectivity and credentials
/// work. Partial pages never clear macOS's independent retry backoff.
struct CatalogRefresh: Sendable {
    let catalog: Catalog
    let publication: CatalogPublication
    let list: @Sendable (String, @escaping @Sendable (RemoteEntry, [RemoteEntry]) async throws -> Void) async throws -> RemoteEntry
    let resolve: @Sendable (NSFileProviderError.Code) async throws -> Void
    let notify: @Sendable () async throws -> Void
    let checkActive: @Sendable () async throws -> Void

    var becameVisible: @Sendable () async -> Void = {}

    func run(parentID: String, path: String) async throws -> Bool {
        let previousGeneration = try await catalog.generation()
        let previousState = try await catalog.connectionState()
        let expectedIdentity: RemoteObjectIdentity?
        if parentID == Catalog.rootID { expectedIdentity = nil }
        else {
            guard let parent = try await catalog.item(id: parentID), !parent.isDeleted else { throw ProviderErrors.noSuchItem() }
            guard let identity = parent.entry.objectIdentity else { throw MutationParentError.refreshRequired(parentID) }
            expectedIdentity = identity
        }
        let scan = try await catalog.beginScan(of: parentID)
        do {
            let directory = try await list(path) { [catalog, publication, becameVisible] held, entries in
                try Task.checkCancellation()
                if try await catalog.stageVisibleAdditions(entries, in: scan, directory: held) {
                    await publication.record(changed: true)
                    await becameVisible()
                }
            }
            try await checkActive()
            guard directory.kind == .directory, let identity = directory.objectIdentity,
                  identity.indexNumber != 0, identity.createdFiletime != 0 else { throw SMBClientError.invalidResponse }
            if let expectedIdentity, expectedIdentity != identity { throw MutationParentError.replaced(parentID) }
            let generation = try await catalog.completeScan(scan, directory: directory)
            await publication.record(changed: generation != previousGeneration)
            if previousState == .offline || previousState == .authenticationRequired {
                // A verified SMB listing proves both conditions, even if the
                // most recent failure obscured an older native error category.
                for code: NSFileProviderError.Code in [.notAuthenticated, .serverUnreachable] {
                    try await checkActive()
                    try await resolve(code)
                }
            }
            try await checkActive()
            try await catalog.setConnectionState(.online)
            try await publication.notify(notify)
            return generation != previousGeneration
        } catch {
            try? await catalog.abandonScan(scan)
            _ = await Self.recordFailure(error, in: catalog)
            throw error
        }
    }

    /// Fetches and writes must record the same native errors they return. This
    /// lets the next verified list recover them without a user reconnect.
    @discardableResult
    static func recordFailure(_ error: Error, in catalog: Catalog) async -> Bool {
        guard let failure = ProviderErrors.translate(error) as? NSFileProviderError else { return false }
        let state: ConnectionState
        switch failure.code {
        case .notAuthenticated: state = .authenticationRequired
        case .serverUnreachable: state = .offline
        default: return false
        }
        try? await catalog.setConnectionState(state)
        return true
    }
}
