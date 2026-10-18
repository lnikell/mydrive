import Foundation
import FileProvider
import MyDriveCore

struct EvictionReport: Sendable {
    let completed: Int
    let retained: [String]
    // Unlike individual retained leaves, failure means the pass was incomplete.
    // Removal must leave the connection available rather than skip unseen items.
    let failure: (any Error)?
}

/// The extension owns reconciliation. The host only configures the connection
/// and asks File Provider to enumerate; it does not run a second NAS mirror.
actor DomainCoordinator {
    let catalog: Catalog
    nonisolated let domainVersionSnapshot: DomainVersionSnapshot
    private let settings: ConnectionSettings
    private let manager: NSFileProviderManager
    private let ownership: DomainOwnerLease
    private let operationGate = DomainOperationGate()
    private let catalogPublication = CatalogPublication()
    private let mutationStaging: MutationStaging
    private var refreshes: [String: Task<Void, Error>] = [:]
    private var reconciliation: Task<Void, Error>?
    private var refreshRetry = RefreshRetryDelay()
    private var invalidated = false
    private var changingOfflinePolicy = false
    private var maintenanceCursor: UUID?
    private var mutationMaintenance = MutationMaintenanceReport()
    #if MYDRIVE_DEVELOPMENT
    private let developmentCredential = DevelopmentCredentialSession()
    private var installingDevelopmentCredential = false
    #endif

    init(identifier: String, displayName: String) throws {
        settings = try AppStorage.settings(for: identifier)
        let catalogURL = try AppStorage.catalogURL(for: identifier)
        ownership = try DomainOwnerLease(at: catalogURL.appendingPathExtension("owner"))
        let openedCatalog = try Catalog(databaseURL: catalogURL,
            initialDomainVersionArchive: DomainVersionSnapshot.initialArchive())
        catalog = openedCatalog
        guard let initialVersion = openedCatalog.initialDomainVersionState else { throw CocoaError(.fileReadCorruptFile) }
        domainVersionSnapshot = try DomainVersionSnapshot(initialVersion)
        mutationStaging = try MutationStaging(root: catalogURL.deletingLastPathComponent().appendingPathComponent("Mutations", isDirectory: true))
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(identifier), displayName: displayName)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.providerNotFound)
        }
        self.manager = manager
    }

    func invalidate() async {
        guard !invalidated else { return }
        invalidated = true
        await operationGate.close()
        #if MYDRIVE_DEVELOPMENT
        await developmentCredential.invalidate()
        #endif
        let wholePass = reconciliation
        let directories = Array(refreshes.values)
        wholePass?.cancel()
        directories.forEach { $0.cancel() }
        refreshes.removeAll()
        for directory in directories { _ = await directory.result }
        _ = await wholePass?.result
    }

    /// Called only after provider and XPC callbacks have drained. Closing the
    /// lease earlier would let a replacement process race outstanding catalog I/O.
    func releaseOwnership() {
        if invalidated { ownership.release() }
    }

    #if MYDRIVE_DEVELOPMENT
    func useDevelopmentCredential(_ password: String) async throws {
        try checkActive()
        guard !installingDevelopmentCredential else {
            throw CocoaError(.fileLocking, userInfo: [
                NSLocalizedDescriptionKey: "Another connection attempt is still running."])
        }
        installingDevelopmentCredential = true
        defer { installingDevelopmentCredential = false }
        let connection = settings
        try await developmentCredential.install(
            password, settings: connection, isDevelopmentBuild: AppStorage.isDevelopmentStorage
        ) { candidate in
            try await SMBClient(settings: connection, developmentPassword: candidate).probe()
        }
        try checkActive()
        refreshRetry.succeeded()
        // macOS retains its own authentication/connectivity backoff separately
        // from the catalog refresh delay. Only a verified credential can clear it.
        try await manager.signalErrorResolved(NSFileProviderError(.notAuthenticated))
        try checkActive()
        try await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable))
        try checkActive()
    }
    #endif

    #if MYDRIVE_DEVELOPMENT
    func forgetDevelopmentCredential() async throws {
        try checkActive()
        guard !installingDevelopmentCredential else {
            throw CocoaError(.fileLocking, userInfo: [
                NSLocalizedDescriptionKey: "Another connection attempt is still running."])
        }
        installingDevelopmentCredential = true
        defer { installingDevelopmentCredential = false }
        try await developmentCredential.forget(
            settings: settings, isDevelopmentBuild: AppStorage.isDevelopmentStorage)
        try checkActive()
    }
    #endif

    private func operationClient() async throws -> SMBClient {
        try checkActive()
        #if MYDRIVE_DEVELOPMENT
        let client = try await developmentCredential.client(
            settings: settings, isDevelopmentBuild: AppStorage.isDevelopmentStorage
        )
        try checkActive()
        return client
        #else
        return SMBClient(settings: settings)
        #endif
    }

    /// The host can request a refresh, but all remote work stays in this owner.
    /// Only directories previously enumerated are revisited; this is not a
    /// recursive discovery of never-opened NAS folders.
    func refreshKnownDirectories() async throws {
        if let running = reconciliation { return try await running.value }
        try checkActive()
        let task = Task { try await self.performKnownDirectoryRefresh() }
        reconciliation = task
        defer { reconciliation = nil }
        try await task.value
    }

    private func performKnownDirectoryRefresh() async throws {
        try await operationGate.perform { try await self.performMutationMaintenance() }
        try await refreshDirectory(parentID: Catalog.rootID)
        var afterID: String?
        while true {
            try checkActive()
            let page = try await catalog.observedDirectories(afterID: afterID, limit: 128)
            for model in page {
                try await refreshDirectory(parentID: model.id)
            }
            guard page.count == 128, let last = page.last else { break }
            afterID = last.id
        }
    }

    private func performMutationMaintenance() async throws {
        try checkActive()
        let report = await mutationAdapter().maintain(after: maintenanceCursor)
        maintenanceCursor = report.nextCursor
        mutationMaintenance = report
    }

    /// Counts describe the last bounded maintenance page, not a whole-domain
    /// inventory. Recovery records remain durable independently of this sample.
    func mutationRecoveryStatus() -> MutationMaintenanceReport { mutationMaintenance }

    func item(id: String) async throws -> ProviderItem {
        try checkActive()
        guard let model = try await catalog.item(id: id), !model.isDeleted,
              try await catalog.relativePath(id: id) != nil else {
            throw ProviderErrors.noSuchItem()
        }
        return try await providerItem(model)
    }

    func children(parentID: String, after cursor: ListingCursor?, limit: Int) async throws -> CatalogPage {
        try checkActive()
        if cursor == nil {
            if try await catalog.hasCompletedScan(of: parentID) {
                // A cached listing is useful immediately. Refresh publishes its
                // completed changes through the working-set notification path.
                startRefresh(parentID: parentID)
            } else {
                try await refreshDirectory(parentID: parentID)
            }
        }
        return try await catalog.children(of: parentID, after: cursor, limit: limit)
    }

    func providerItems(_ models: [CatalogItem]) async throws -> [ProviderItem] {
        var result: [ProviderItem] = []
        result.reserveCapacity(models.count)
        for model in models {
            try checkActive()
            result.append(try await providerItem(model))
        }
        return result
    }

    func generation() async throws -> Int64 {
        try checkActive()
        return try await catalog.generation()
    }

    func currentChangeAnchor() async throws -> Int64 {
        try checkActive()
        return try await catalog.currentChangeAnchor()
    }

    func changes(since anchor: Int64, for identifier: NSFileProviderItemIdentifier, limit: Int = 128) async throws -> CatalogChangePage {
        try checkActive()
        if identifier == .workingSet { return try await catalog.changes(since: anchor, limit: limit) }
        let id = ProviderItem.catalogID(identifier)
        // Keep deleted documents scoped to their own identity as well. Looking
        // only at live items would turn their final notification into an error.
        let model = try await catalog.item(id: id)
        if id == Catalog.rootID || model?.entry.kind == .directory {
            return try await catalog.changes(since: anchor, in: id, limit: limit)
        }
        return try await catalog.changes(since: anchor, itemID: id, limit: limit)
    }

    func knownItems(afterID: String?, limit: Int) async throws -> [CatalogItem] {
        try checkActive()
        return try await catalog.knownItems(afterID: afterID, limit: limit)
    }

    func fetch(id: String, version: Data?, progress: Progress) async throws -> (URL, ProviderItem) {
        let original = try await item(id: id)
        guard original.model.entry.kind == .file,
              let path = try await catalog.relativePath(id: id) else {
            throw CocoaError(.featureUnsupported)
        }
        if let version, version != original.itemVersion.contentVersion {
            startRefresh(parentID: original.model.parentID ?? Catalog.rootID)
            throw NSFileProviderError(.versionNoLongerAvailable)
        }

        let transfer = ContentFetchProgress(progress, expectedBytes: original.model.entry.size)
        let temporary = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
        do {
            let client = try await operationClient()
            let downloaded = try await client.download(path: path, to: temporary) { completed in
                transfer.received(completed)
            }
            try transfer.finish {
                try checkActive()
                if downloaded.contentVersion != original.model.entry.contentVersion {
                    // Do not label newer NAS bytes with the old catalog revision.
                    // Reconcile metadata, then let the system request that revision.
                    startRefresh(parentID: original.model.parentID ?? Catalog.rootID)
                    throw NSFileProviderError(.versionNoLongerAvailable)
                }
                guard original.model.entry.size == downloaded.size else {
                    throw NSFileProviderError(.versionNoLongerAvailable)
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
                guard (attributes[.size] as? NSNumber)?.int64Value == downloaded.size else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try checkActive()
            }
            return (temporary, original)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            await CatalogRefresh.recordFailure(error, in: catalog)
            throw error
        }
    }

    func write(_ input: MutationInput, create: Bool, progress: Progress) async throws -> ProviderItem {
        try await operationGate.perform {
            try await self.performWrite(input, create: create, progress: progress)
        }
    }

    private func performWrite(_ input: MutationInput, create: Bool, progress: Progress) async throws -> ProviderItem {
        try checkActive()
        let result: CatalogItem
        do { result = try await mutationAdapter().write(input, create: create, progress: progress) }
        catch { await recordMutationFailure(error); throw error }
        // Publication succeeded already. A failed notification must not turn a
        // committed upload into a second remote write on the next callback.
        await recordMutationPublication()
        startRefresh(parentID: result.parentID ?? Catalog.rootID)
        return try await providerItem(result)
    }

    func delete(id: String, contentVersion: Data, metadataVersion: Data,
                requestContext: DeletionRequestContext? = nil, progress: Progress) async throws {
        try await operationGate.perform {
            try await self.performDelete(id: id, contentVersion: contentVersion,
                                         metadataVersion: metadataVersion, requestContext: requestContext, progress: progress)
        }
    }

    func deletionRequestContext(archive: Data?, recursive: Bool) async throws -> DeletionRequestContext {
        try checkActive()
        return try await domainVersionSnapshot.resolve(archive, recursive: recursive) { [catalog] epoch in
            try await catalog.domainVersionState(epoch: epoch)
        }
    }

    private func performDelete(id: String, contentVersion: Data, metadataVersion: Data,
                               requestContext: DeletionRequestContext?, progress: Progress) async throws {
        try checkActive()
        do {
            if let requestContext, requestContext.recursive,
               let item = try await catalog.item(id: id), item.entry.kind == .directory {
                let driver = ProviderRecursiveDelete(mutations: mutationAdapter(), versions: domainVersionSnapshot,
                    published: { await self.recordMutationPublication() })
                try await driver.delete(id: id, contentVersion: contentVersion, metadataVersion: metadataVersion,
                                        context: requestContext, progress: progress)
            } else {
                try await mutationAdapter().delete(id: id, contentVersion: contentVersion,
                                                   metadataVersion: metadataVersion, progress: progress)
            }
        } catch {
            await recordMutationFailure(error)
            let native = ProviderErrors.translate(error) as NSError
            if native.domain == NSFileProviderErrorDomain,
               [NSFileProviderError.deletionRejected.rawValue, NSFileProviderError.directoryNotEmpty.rawValue,
                NSFileProviderError.cannotSynchronize.rawValue].contains(native.code),
               let root = try? await catalog.item(id: id), let parent = root.parentID {
                startRefresh(parentID: parent)
            }
            throw error
        }
        await recordMutationPublication()
    }

    private func mutationAdapter() -> ProviderMutations {
        ProviderMutations(catalog: catalog, staging: mutationStaging,
                          remote: MutationRemote(client: { try await self.operationClient() }),
                          checkActive: { try await self.checkActive() })
    }

    private func recordMutationFailure(_ error: Error) async {
        await CatalogRefresh.recordFailure(error, in: catalog)
        if let failure = error as? MutationParentError,
           let parent = try? await catalog.item(id: failure.parentID) {
            // Parent metadata comes from its containing directory's listing.
            startRefresh(parentID: parent.parentID ?? Catalog.rootID)
        }
    }

    private func recordMutationPublication() async {
        await catalogPublication.record(changed: true)
        try? await catalogPublication.notify { try await self.notifyCatalogChanges() }
    }

    func keepDownloaded(_ identifiers: [String]) async throws {
        try beginOfflinePolicyChange()
        defer { changingOfflinePolicy = false }
        guard !identifiers.isEmpty, identifiers.count <= 1_000 else { throw CatalogError.invalidEntry }
        let ids = Set(identifiers.map { ProviderItem.catalogID(NSFileProviderItemIdentifier($0)) })
        for id in ids { _ = try await item(id: id) }
        for id in ids {
            try checkActive()
            try await catalog.setOfflinePolicy(.keepAvailable, for: id)
        }
        try checkActive()
        try await manager.signalEnumerator(for: .workingSet)
        for id in ids {
            try checkActive()
            manager.requestDownloadForItem(withIdentifier: ProviderItem.identifier(id), requestedRange: nil) { @Sendable _ in }
        }
    }

    func freeUpSpace(_ identifiers: [String]?) async throws -> EvictionReport {
        try beginOfflinePolicyChange()
        defer { changingOfflinePolicy = false }
        let roots: [String]
        if let identifiers {
            guard !identifiers.isEmpty, identifiers.count <= 1_000 else { throw CatalogError.invalidEntry }
            roots = Array(Set(identifiers.map { ProviderItem.catalogID(NSFileProviderItemIdentifier($0)) }))
        } else {
            roots = [Catalog.rootID]
        }
        var prefixes: [String] = []
        for root in roots {
            try checkActive()
            guard let path = try await catalog.relativePath(id: root) else { throw ProviderErrors.noSuchItem() }
            prefixes.append(path)
        }
        for root in roots {
            try checkActive()
            try await catalog.clearOfflineSelections(in: root)
        }
        try checkActive()
        try await manager.signalEnumerator(for: .workingSet)

        let policyEviction = PolicyAwareEviction()
        var evicted = 0
        var retained = 0
        var messages: [String] = []
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        var page = MaterializedPage.initialPage
        do {
            repeat {
                try checkActive()
                let materialized = try await MaterializedPage.read(from: enumerator, startingAt: page)
                for identifier in materialized.identifiers {
                    try checkActive()
                    let id = ProviderItem.catalogID(NSFileProviderItemIdentifier(identifier))
                    guard let model = try await catalog.item(id: id), model.entry.kind == .file,
                          let path = try await catalog.relativePath(id: id),
                          prefixes.contains(where: { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                    try checkActive()
                    do {
                        let result = try await policyEviction.evict(
                            isKeptDownloaded: { [catalog] in
                                try await catalog.offlinePolicy(for: id) == .keepAvailable
                            },
                            checkActive: { try await self.checkActive() },
                            attempt: { try await self.evictFile(id: id) })
                        if result == .evicted { evicted += 1 }
                        else {
                            retained += 1
                            if messages.count < 100 {
                                messages.append("\(model.entry.name): kept by an offline selection.")
                            }
                        }
                    } catch {
                        try checkActive()
                        retained += 1
                        if messages.count < 100 {
                            messages.append("\(model.entry.name): \(error.localizedDescription)")
                        }
                    }
                    try checkActive()
                }
                guard let next = materialized.next else { break }
                page = next
            } while true
        } catch {
            return EvictionReport(completed: evicted, retained: messages, failure: error)
        }
        if retained > messages.count {
            messages.append("\(retained - messages.count) additional files retained.")
        }
        return EvictionReport(completed: evicted, retained: messages, failure: nil)
    }

    /// Uses only native cache metadata and OS eviction. Writes may still be
    /// pending: their protection comes from macOS, never from a clean-state guess.
    func prepareForRemoval() async throws -> EvictionReport {
        try beginOfflinePolicyChange()
        defer { changingOfflinePolicy = false }
        let pass = RemovalEviction()
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        return try await pass.run(preparePolicy: {
            try await pass.clearSelections(in: self.catalog, checkActive: { try await self.checkActive() })
            try self.checkActive()
            try await RemovalEvictionRequest.run(until: pass.requestDeadline) { finish in
                self.manager.signalEnumerator(for: .workingSet) { @Sendable error in finish(error) }
            }
        }, checkActive: { try self.checkActive() }, readPage: { page, remaining in
            try await MaterializedPage.read(from: enumerator, startingAt: page, timeout: remaining)
        }, evict: { identifier in
            let id = ProviderItem.catalogID(NSFileProviderItemIdentifier(identifier))
            return try await pass.evict(isKeptDownloaded: {
                guard try await self.catalog.item(id: id) != nil else { return false }
                return try await self.catalog.offlinePolicy(for: id) == .keepAvailable
            }, checkActive: { try await self.checkActive() }, attempt: { deadline in
                try await self.evictForRemoval(identifier: identifier, deadline: deadline)
            })
        })
    }

    private func evictForRemoval(identifier: String, deadline: ContinuousClock.Instant) async throws {
        try checkActive()
        try await RemovalEvictionRequest.run(until: deadline) { finish in
            manager.evictItem(identifier: NSFileProviderItemIdentifier(identifier)) { @Sendable error in finish(error) }
        }
    }

    private func providerItem(_ model: CatalogItem) async throws -> ProviderItem {
        let policy = try await catalog.offlinePolicy(for: model.id)
        return ProviderItem(model, policy: policy, displayName: settings.displayName)
    }

    private func evictFile(id: String) async throws {
        try checkActive()
        try await manager.evictItem(identifier: ProviderItem.identifier(id))
    }

    private func startRefresh(parentID: String) {
        guard refreshes[parentID] == nil, !invalidated else { return }
        Task {
            do { try await self.refreshDirectory(parentID: parentID) }
            catch { /* Cached metadata remains valid; the next access retries. */ }
        }
    }

    private func refreshDirectory(parentID: String) async throws {
        if let running = refreshes[parentID] {
            return try await running.value
        }
        try checkActive()
        let task = Task { try await self.performRefresh(parentID: parentID) }
        refreshes[parentID] = task
        defer { refreshes.removeValue(forKey: parentID) }
        try await task.value
    }

    private func performRefresh(parentID: String) async throws {
        try await operationGate.perform { try await self.performRefreshLocked(parentID: parentID) }
    }

    private func performRefreshLocked(parentID: String) async throws {
        // Cached directory pages never await this path. While a retry waits,
        // refreshes[parentID] keeps repeated requests on the same owned task.
        try await refreshRetry.wait()
        try checkActive()
        guard let path = try await catalog.relativePath(id: parentID) else {
            throw ProviderErrors.noSuchItem()
        }
        let refresh = CatalogRefresh(catalog: catalog, publication: catalogPublication, list: { path, page in
            let client = try await self.operationClient()
            return try await client.listDirectory(path: path, pageSize: 128, onPage: page).observation
        }, resolve: { code in try await self.resolveConnectionError(code) },
           notify: { try await self.notifyCatalogChanges() },
           checkActive: { try await self.checkActive() })
        do {
            _ = try await refresh.run(parentID: parentID, path: path)
            refreshRetry.succeeded()
        } catch {
            await recordMutationFailure(error)
            if let failure = ProviderErrors.translate(error) as? NSFileProviderError,
               failure.code == .notAuthenticated || failure.code == .serverUnreachable {
                refreshRetry.failed()
            }
            throw error
        }
    }

    private func resolveConnectionError(_ code: NSFileProviderError.Code) async throws {
        try checkActive()
        try await manager.signalErrorResolved(NSFileProviderError(code))
    }

    private func notifyCatalogChanges() async throws {
        try checkActive()
        try await manager.signalEnumerator(for: .workingSet)
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if invalidated { throw CancellationError() }
    }

    private func beginOfflinePolicyChange() throws {
        try checkActive()
        guard !changingOfflinePolicy else {
            throw CocoaError(.fileLocking, userInfo: [
                NSLocalizedDescriptionKey: "Another offline operation is still running."])
        }
        changingOfflinePolicy = true
    }
}
