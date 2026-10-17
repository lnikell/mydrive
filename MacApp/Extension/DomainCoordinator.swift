import Foundation
import FileProvider
import MyDriveCore

struct EvictionReport: Sendable {
    let completed: Int
    let retained: [String]
    let failure: (any Error)?
}

/// The extension owns reconciliation. The host only configures the connection
/// and asks File Provider to enumerate; it does not run a second NAS mirror.
actor DomainCoordinator {
    let catalog: Catalog
    private let settings: ConnectionSettings
    private let manager: NSFileProviderManager
    private let ownership: DomainOwnerLease
    private var refreshes: [String: Task<Void, Error>] = [:]
    private var reconciliation: Task<Void, Error>?
    private var refreshRetry = RefreshRetryDelay()
    private var invalidated = false
    private var changingOfflinePolicy = false
    #if MYDRIVE_DEVELOPMENT
    private let developmentCredential = DevelopmentCredentialSession()
    private var installingDevelopmentCredential = false
    #endif

    init(identifier: String, displayName: String) throws {
        settings = try AppStorage.settings(for: identifier)
        let catalogURL = try AppStorage.catalogURL(for: identifier)
        ownership = try DomainOwnerLease(at: catalogURL.appendingPathExtension("owner"))
        catalog = try Catalog(databaseURL: catalogURL)
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(identifier), displayName: displayName)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.providerNotFound)
        }
        self.manager = manager
    }

    func invalidate() async {
        guard !invalidated else { return }
        invalidated = true
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
            throw error
        }
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
        var page = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
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
        // Cached directory pages never await this path. While a retry waits,
        // refreshes[parentID] keeps repeated requests on the same owned task.
        try await refreshRetry.wait()
        try checkActive()
        guard let path = try await catalog.relativePath(id: parentID) else {
            throw ProviderErrors.noSuchItem()
        }
        let previousGeneration = try await catalog.generation()
        let scan = try await catalog.beginScan(of: parentID)
        do {
            let client = try await operationClient()
            try await client.list(path: path, pageSize: 128) { [catalog] entries in
                try Task.checkCancellation()
                try await catalog.stage(entries, in: scan)
            }
            try checkActive()
            let generation = try await catalog.completeScan(scan)
            refreshRetry.succeeded()
            try await catalog.setConnectionState(.online)
            if generation != previousGeneration {
                try await manager.signalEnumerator(for: .workingSet)
            }
        } catch {
            try? await catalog.abandonScan(scan)
            // Use the same classification macOS receives, including a locked
            // development Keychain. Never retry a credential read in a loop.
            if let failure = ProviderErrors.translate(error) as? NSFileProviderError {
                switch failure.code {
                case .notAuthenticated:
                    refreshRetry.failed()
                    try? await catalog.setConnectionState(.authenticationRequired)
                case .serverUnreachable:
                    refreshRetry.failed()
                    try? await catalog.setConnectionState(.offline)
                default:
                    break
                }
            }
            throw error
        }
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
