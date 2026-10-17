import Foundation
import FileProvider
import MyDriveCore

/// File Provider caps opaque page data at 500 bytes. Keep long names/cursors
/// inside this enumerator and hand the system a small, expiring token.
private actor EnumerationCursors {
    enum Cursor: Sendable {
        case directory(ListingCursor)
        case workingSet(afterID: String?, generation: Int64)
    }
    private var values: [String: Cursor] = [:]

    func value(for page: NSFileProviderPage) throws -> Cursor {
        guard let key = String(data: page.rawValue, encoding: .utf8),
              let cursor = values[key] else { throw ProviderErrors.expiredPage() }
        return cursor
    }

    func page(for cursor: Cursor) -> NSFileProviderPage {
        // Enumeration is sequential. Expiring old tokens is safer than keeping
        // every page of a million-item share resident for the enumerator's life.
        if values.count >= 16 { values.removeAll() }
        let key = UUID().uuidString
        values[key] = cursor
        return NSFileProviderPage(Data(key.utf8))
    }
}

final class CatalogEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let identifier: NSFileProviderItemIdentifier
    private let coordinator: DomainCoordinator
    private let cursors = EnumerationCursors()
    private let tasks = ProviderTasks()

    init(identifier: NSFileProviderItemIdentifier, coordinator: DomainCoordinator) {
        self.identifier = identifier
        self.coordinator = coordinator
    }

    func invalidate() { tasks.invalidate() }

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let callback = ProviderCallback(observer)
        let size = min(128, max(1, observer.suggestedPageSize ?? 128))
        _ = tasks.run { [self] _ in
            do {
                try Task.checkCancellation()
                if identifier == .workingSet {
                    try await enumerateWorkingSet(observer: callback.value, page: page, limit: size)
                } else {
                    try await enumerateDirectory(observer: callback.value, page: page, limit: size)
                }
            } catch {
                callback.value.finishEnumeratingWithError(ProviderErrors.translate(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let callback = ProviderCallback(completionHandler)
        _ = tasks.run { [coordinator] _ in
            let sequence = try? await coordinator.currentChangeAnchor()
            callback.value(sequence.map(CatalogChangeAnchor.encode))
        }
    }

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let callback = ProviderCallback(observer)
        let size = min(128, max(1, observer.suggestedBatchSize ?? 128))
        _ = tasks.run { [coordinator, identifier] _ in
            do {
                let sequence = try CatalogChangeAnchor.decode(anchor)
                let page = try await coordinator.changes(since: sequence, for: identifier, limit: size)
                let items = try await coordinator.providerItems(page.updated)
                try Task.checkCancellation()
                if !items.isEmpty { callback.value.didUpdate(items) }
                if !page.deletedIDs.isEmpty {
                    callback.value.didDeleteItems(withIdentifiers: page.deletedIDs.map(ProviderItem.identifier))
                }
                callback.value.finishEnumeratingChanges(
                    upTo: CatalogChangeAnchor.encode(page.anchor), moreComing: page.moreComing)
            } catch {
                callback.value.finishEnumeratingWithError(ProviderErrors.translate(error))
            }
        }
    }

    private func enumerateDirectory(
        observer: any NSFileProviderEnumerationObserver, page: NSFileProviderPage, limit: Int
    ) async throws {
        let cursor: ListingCursor?
        if Self.isInitial(page) {
            cursor = nil
        } else {
            guard case .directory(let stored) = try await cursors.value(for: page) else {
                throw ProviderErrors.expiredPage()
            }
            cursor = stored
        }
        let result = try await coordinator.children(
            parentID: ProviderItem.catalogID(identifier), after: cursor, limit: limit)
        let items = try await coordinator.providerItems(result.items)
        try Task.checkCancellation()
        observer.didEnumerate(items)
        let next: NSFileProviderPage?
        if let cursor = result.nextCursor {
            next = await cursors.page(for: .directory(cursor))
        } else {
            next = nil
        }
        observer.finishEnumerating(upTo: next)
    }

    private func enumerateWorkingSet(
        observer: any NSFileProviderEnumerationObserver, page: NSFileProviderPage, limit: Int
    ) async throws {
        let generation: Int64
        let afterID: String?
        if Self.isInitial(page) {
            generation = try await coordinator.generation()
            afterID = nil
        } else {
            guard case .workingSet(let storedID, let storedGeneration) = try await cursors.value(for: page) else {
                throw ProviderErrors.expiredPage()
            }
            generation = storedGeneration
            afterID = storedID
        }
        guard try await coordinator.generation() == generation else { throw ProviderErrors.expiredPage() }
        // Root policy changes must also reach macOS. knownItems deliberately
        // excludes the root, so include it explicitly on the first page.
        let initial = Self.isInitial(page)
        let capacity = initial ? limit - 1 : limit
        let models = capacity > 0 ? try await coordinator.knownItems(afterID: afterID, limit: capacity) : []
        var items = try await coordinator.providerItems(models)
        if initial { items.insert(try await coordinator.item(id: Catalog.rootID), at: 0) }
        guard try await coordinator.generation() == generation else { throw ProviderErrors.expiredPage() }
        try Task.checkCancellation()
        observer.didEnumerate(items)
        let next: NSFileProviderPage?
        if capacity == 0 {
            next = await cursors.page(for: .workingSet(afterID: nil, generation: generation))
        } else if models.count == capacity, let last = models.last {
            next = await cursors.page(for: .workingSet(afterID: last.id, generation: generation))
        } else {
            next = nil
        }
        observer.finishEnumerating(upTo: next)
    }

    private static func isInitial(_ page: NSFileProviderPage) -> Bool {
        page.rawValue == NSFileProviderPage.initialPageSortedByName as Data ||
            page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data
    }

}
