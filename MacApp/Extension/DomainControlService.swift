import Foundation
import FileProvider

/// Restricted File Provider service: only domain-managing processes can obtain
/// this endpoint through NSFileProviderManager.
final class DomainControlService: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, @unchecked Sendable {
    var serviceName: NSFileProviderServiceName { domainControlServiceName }
    var isRestricted: Bool { true }

    private let listener = NSXPCListener.anonymous()
    private let coordinator: DomainCoordinator
    private let tasks = ProviderTasks()
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]
    private var closed = false

    init(coordinator: DomainCoordinator) {
        self.coordinator = coordinator
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint { listener.endpoint }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let identifier = ObjectIdentifier(connection)
        let scope = tasks.makeScope()
        connection.exportedInterface = NSXPCInterface(with: DomainControlProtocol.self)
        connection.exportedObject = DomainControl(coordinator: coordinator, tasks: scope)
        connection.invalidationHandler = { @Sendable [weak self] in
            scope.invalidate()
            self?.remove(identifier)
        }
        lock.lock()
        guard !closed else { lock.unlock(); scope.invalidate(); return false }
        connections[identifier] = connection
        lock.unlock()
        connection.resume()
        return true
    }

    func invalidate() -> [Task<Void, Never>] {
        lock.lock()
        closed = true
        let active = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        listener.invalidate()
        let pending = tasks.invalidate()
        active.forEach { $0.invalidate() }
        return pending
    }

    private func remove(_ identifier: ObjectIdentifier) {
        lock.lock()
        connections.removeValue(forKey: identifier)
        lock.unlock()
    }
}

private final class DomainControl: NSObject, DomainControlProtocol, @unchecked Sendable {
    private let coordinator: DomainCoordinator
    private let tasks: ProviderTasks.Scope

    init(coordinator: DomainCoordinator, tasks: ProviderTasks.Scope) {
        self.coordinator = coordinator
        self.tasks = tasks
    }

    #if MYDRIVE_DEVELOPMENT
    func useDevelopmentCredential(_ password: String, reply: @escaping (NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do {
                try await coordinator.useDevelopmentCredential(password)
                callback.value(nil)
            } catch {
                callback.value(ProviderErrors.translate(error) as NSError)
            }
        }
    }

    func forgetDevelopmentCredential(reply: @escaping (NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do {
                try await coordinator.forgetDevelopmentCredential()
                callback.value(nil)
            } catch {
                callback.value(ProviderErrors.translate(error) as NSError)
            }
        }
    }
    #endif

    func refresh(reply: @escaping (NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do {
                try await coordinator.refreshKnownDirectories()
                callback.value(nil)
            } catch {
                callback.value(ProviderErrors.translate(error) as NSError)
            }
        }
    }

    func keepDownloaded(_ identifiers: [String], reply: @escaping (NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do {
                try await coordinator.keepDownloaded(identifiers)
                callback.value(nil)
            } catch {
                callback.value(ProviderErrors.translate(error) as NSError)
            }
        }
    }

    func freeUpSpace(_ identifiers: [String], reply: @escaping (Int, [String], NSError?) -> Void) {
        free(identifiers, reply: reply)
    }

    func freeUpAllSpace(reply: @escaping (Int, [String], NSError?) -> Void) {
        free(nil, reply: reply)
    }

    func prepareForRemoval(reply: @escaping (Int, [String], NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do {
                let report = try await coordinator.prepareForRemoval()
                callback.value(report.completed, report.retained, report.failure.map { ProviderErrors.translate($0) as NSError })
            } catch {
                callback.value(0, [], ProviderErrors.translate(error) as NSError)
            }
        }
    }

    private func free(_ identifiers: [String]?, reply: @escaping (Int, [String], NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do {
                let report = try await coordinator.freeUpSpace(identifiers)
                callback.value(report.completed, report.retained, report.failure.map { ProviderErrors.translate($0) as NSError })
            } catch {
                callback.value(0, [], ProviderErrors.translate(error) as NSError)
            }
        }
    }
}
