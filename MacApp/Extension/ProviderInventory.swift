import Darwin
import FileProvider
import Foundation
import MyDriveCore

struct ReplicaMetadata: Sendable {
    let downloaded: Bool
    let allocated: Int64
    let lastOpened: Date

    static func read(_ identifier: String, manager: NSFileProviderManager,
                     isolation: isolated (any Actor)? = #isolation) async throws -> Self {
        let url = try await manager.getUserVisibleURL(for: ProviderItem.identifier(identifier))
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return Self(downloaded: false, allocated: 0, lastOpened: .distantPast) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return Self(downloaded: info.st_flags & UInt32(SF_DATALESS) == 0,
                    allocated: max(0, info.st_blocks) > Int64.max / 512 ? .max : max(0, info.st_blocks) * 512,
                    lastOpened: Date(timeIntervalSince1970: Double(info.st_atimespec.tv_sec)))
    }
}

/// Read projections only. The owning coordinator supplies its Catalog and the
/// native manager; no payload is opened and no new directory scan is started.
enum ProviderInventory {
    static func library(catalog: Catalog, manager: NSFileProviderManager, scope: LibraryScope,
                        afterID: String?, expectedGeneration: Int64?,
                        isolation: isolated (any Actor)? = #isolation) async throws -> LibraryPage {
        let generation = try await catalog.generation()
        if let expectedGeneration, expectedGeneration != generation { throw CatalogError.staleCursor }
        let page = try await (scope == .keptOffline
            ? catalog.offlineSelections(afterID: afterID, limit: 128)
            : catalog.knownItems(afterID: afterID, limit: 128))
        var entries: [LibraryEntry] = []
        for item in page {
            try Task.checkCancellation()
            guard let path = try await catalog.relativePath(id: item.id) else { continue }
            let metadata = try? await ReplicaMetadata.read(item.id, manager: manager)
            let offline = try await catalog.offlinePolicy(for: item.id) == .keepAvailable
            if scope == .onlineOnly {
                guard item.entry.kind == .file, !offline, metadata?.downloaded == false else { continue }
            }
            entries.append(LibraryEntry(id: item.id, name: item.entry.name, path: path,
                folder: item.entry.kind == .directory, size: item.entry.size,
                keptOffline: offline,
                // A resident directory says nothing about its descendants.
                // Keep the folder selection visible without claiming all of
                // its files have finished downloading.
                downloaded: item.entry.kind == .file ? metadata?.downloaded : nil))
        }
        guard try await catalog.generation() == generation else { throw CatalogError.staleCursor }
        return LibraryPage(entries: entries, nextID: page.count == 128 ? page.last?.id : nil, generation: generation)
    }

    static func cache(catalog: Catalog, manager: NSFileProviderManager,
                      isolation: isolated (any Actor)? = #isolation) async throws -> CacheUsage {
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        var page = MaterializedPage.initialPage, usage = CacheUsage()
        let counts = try await catalog.libraryCounts()
        usage.onlineOnlyCount = counts.onDemandFiles
        usage.offlineSelectionCount = counts.explicitSelections
        repeat {
            let result = try await MaterializedPage.read(from: enumerator, startingAt: page)
            for item in result.items where item.kind == .leaf {
                try Task.checkCancellation()
                let id = ProviderItem.catalogID(NSFileProviderItemIdentifier(item.identifier))
                guard let model = try await catalog.item(id: id), !model.isDeleted else { continue }
                let metadata = try await ReplicaMetadata.read(id, manager: manager)
                if try await catalog.offlinePolicy(for: id) == .keepAvailable { usage.keptOffline = NonnegativeTotals.add(usage.keptOffline, metadata.allocated) }
                else {
                    usage.cached = NonnegativeTotals.add(usage.cached, metadata.allocated)
                    if model.entry.kind == .file && metadata.downloaded { usage.onlineOnlyCount = max(0, usage.onlineOnlyCount - 1) }
                }
            }
            guard let next = result.next else { break }
            page = next
        } while true
        let root = try AppStorage.rootURL()
        usage.free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        usage.measuredAt = Date()
        return usage
    }
}
