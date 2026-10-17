import Foundation
import FileProvider

@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing, NSFileProviderCustomAction, NSFileProviderDomainState, @unchecked Sendable {
    private let coordinator: Result<DomainCoordinator, Error>
    private let control: Result<DomainControlService, Error>
    private let tasks = ProviderTasks()
    private let lifecycleLock = NSLock()
    private var invalidated = false

    var domainVersion: NSFileProviderDomainVersion {
        (try? coordinator.get())?.domainVersionSnapshot.domainVersion ?? DomainVersionSnapshot.unavailable.domainVersion
    }

    var userInfo: [AnyHashable: Any] { [:] }

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
        if containerItemIdentifier == .trashContainer { throw CocoaError(.featureUnsupported) }
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

    func createItem(
        basedOn itemTemplate: any NSFileProviderItem, fields: NSFileProviderItemFields,
        contents: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        #if MYDRIVE_DEVELOPMENT
        DevelopmentPayloadShape.observe(contents, contentType: itemTemplate.contentType?.identifier ?? "unknown",
            operation: "create", fields: fields.rawValue, options: options.rawValue)
        #endif
        let input = Result { try MutationInput(item: itemTemplate, fields: fields, contents: contents,
                                               allowDirectoryContents: true) }
        let callback = ProviderCallback(completionHandler)
        return tasks.run { [coordinator] progress in
            do {
                let input = try input.get()
                let item = try await coordinator.get().write(input, create: true, progress: progress)
                callback.value(item, input.pendingFields, false, nil)
            } catch {
                callback.value(nil, [], false, ProviderErrors.translate(error))
            }
        }
    }

    func modifyItem(
        _ item: any NSFileProviderItem, baseVersion: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields, contents: URL?, options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        #if MYDRIVE_DEVELOPMENT
        DevelopmentPayloadShape.observe(contents, contentType: item.contentType?.identifier ?? "unknown",
            operation: "modify", fields: changedFields.rawValue, options: options.rawValue)
        #endif
        let input = Result { try MutationInput(item: item, fields: changedFields, contents: contents, baseVersion: baseVersion) }
        let callback = ProviderCallback(completionHandler)
        return tasks.run { [coordinator] progress in
            do {
                let input = try input.get()
                let item = try await coordinator.get().write(input, create: false, progress: progress)
                callback.value(item, input.pendingFields, false, nil)
            } catch {
                callback.value(nil, [], false, ProviderErrors.translate(error))
            }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
        completionHandler: @escaping ((any Error)?) -> Void
    ) -> Progress {
        let id = ProviderItem.catalogID(identifier)
        let content = baseVersion.contentVersion
        let metadata = baseVersion.metadataVersion
        let requestArchive = Result { try DomainVersionSnapshot.archive(request.domainVersion) }
        let recursive = options.contains(.recursive)
        let callback = ProviderCallback(completionHandler)
        return tasks.run { [coordinator] progress in
            do {
                let owner = try coordinator.get()
                let context = try await owner.deletionRequestContext(archive: requestArchive.get(), recursive: recursive)
                try await owner.delete(id: id, contentVersion: content,
                                       metadataVersion: metadata, requestContext: context, progress: progress)
                callback.value(nil)
            } catch { callback.value(ProviderErrors.translate(error)) }
        }
    }
}
