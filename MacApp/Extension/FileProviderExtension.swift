import Foundation
import FileProvider

@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing, NSFileProviderCustomAction, @unchecked Sendable {
    private let coordinator: Result<DomainCoordinator, Error>
    private let control: Result<DomainControlService, Error>
    private let tasks = ProviderTasks()
    private let lifecycleLock = NSLock()
    private var invalidated = false

    required init(domain: NSFileProviderDomain) {
        let coordinator = Result {
            try DomainCoordinator(identifier: domain.identifier.rawValue, displayName: domain.displayName)
        }
        self.coordinator = coordinator
        control = coordinator.map { DomainControlService(coordinator: $0) }
        super.init()
    }

    func invalidate() {
        lifecycleLock.lock()
        guard !invalidated else { lifecycleLock.unlock(); return }
        invalidated = true
        lifecycleLock.unlock()
        var pending = tasks.invalidate()
        if let control = try? control.get() { pending += control.invalidate() }
        if let coordinator = try? coordinator.get() {
            let operations = pending
            Task {
                await coordinator.invalidate()
                for operation in operations { await operation.value }
                await coordinator.releaseOwnership()
            }
        }
    }

    func supportedServiceSources(
        for itemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping ([any NSFileProviderServiceSource]?, (any Error)?) -> Void
    ) -> Progress {
        do { completionHandler([try control.get()], nil) }
        catch { completionHandler(nil, ProviderErrors.translate(error)) }
        return Progress(totalUnitCount: 0)
    }

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        let action = actionIdentifier.rawValue
        let identifiers = itemIdentifiers.map(\.rawValue)
        let callback = ProviderCallback(completionHandler)
        return tasks.run { [coordinator] progress in
            do {
                let handler = try ProviderActionHandler(coordinator: coordinator.get())
                try await handler.perform(action: action, on: identifiers)
                try Task.checkCancellation()
                progress.completedUnitCount = 1
                callback.value(nil)
            } catch {
                callback.value(ProviderErrors.translate(error))
            }
        }
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
    ) throws -> any NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer { throw ProviderErrors.noSuchItem() }
        return try CatalogEnumerator(identifier: containerItemIdentifier, coordinator: coordinator.get())
    }

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, (any Error)?) -> Void
    ) -> Progress {
        let callback = ProviderCallback(completionHandler)
        return tasks.run { [coordinator] progress in
            do {
                let item = try await coordinator.get().item(id: ProviderItem.catalogID(identifier))
                try Task.checkCancellation()
                progress.completedUnitCount = 1
                callback.value(item, nil)
            } catch {
                callback.value(nil, ProviderErrors.translate(error))
            }
        }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, (any NSFileProviderItem)?, (any Error)?) -> Void
    ) -> Progress {
        let callback = ProviderCallback(completionHandler)
        let version = requestedVersion?.contentVersion
        return tasks.run { [coordinator] progress in
            do {
                let (url, item) = try await coordinator.get().fetch(
                    id: ProviderItem.catalogID(itemIdentifier), version: version, progress: progress)
                // The system takes ownership of this regular staging file.
                callback.value(url, item, nil)
            } catch {
                callback.value(nil, nil, ProviderErrors.translate(error))
            }
        }
    }

    // The alpha supports genuine NAS reads. It never acknowledges an attempted
    // write as uploaded, including changes initiated outside Finder's UI.
    func createItem(
        basedOn itemTemplate: any NSFileProviderItem, fields: NSFileProviderItemFields,
        contents: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        completionHandler(nil, fields, false, ProviderErrors.readOnly())
        return Progress(totalUnitCount: 0)
    }

    func modifyItem(
        _ item: any NSFileProviderItem, baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        completionHandler(nil, changedFields, false, ProviderErrors.readOnly())
        return Progress(totalUnitCount: 0)
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        completionHandler(ProviderErrors.readOnly())
        return Progress(totalUnitCount: 0)
    }
}
