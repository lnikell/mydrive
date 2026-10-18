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

    func snapshot(_ measureCache: Bool, reply: @escaping (Data?, NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do { callback.value(try await coordinator.snapshot(measureCache: measureCache).encodedForControl(), nil) }
            catch { callback.value(nil, ProviderErrors.translate(error) as NSError) }
        }
    }

    func library(_ scope: String, afterID: String?, generation: NSNumber?, reply: @escaping (Data?, NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        let expectedGeneration = generation?.int64Value
        _ = tasks.run { [coordinator] _ in
            do {
                guard let scope = LibraryScope(rawValue: scope), (afterID?.utf8.count ?? 0) <= 128 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let page = try await coordinator.library(scope: scope, afterID: afterID, generation: expectedGeneration)
                callback.value(try page.encodedForControl(), nil)
            } catch { callback.value(nil, ProviderErrors.translate(error) as NSError) }
        }
    }

    func clearActivity(reply: @escaping (NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            await coordinator.clearActivity()
            callback.value(nil)
        }
    }

    func resolveActivity(_ identifier: String, reply: @escaping (NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do {
                guard let id = UUID(uuidString: identifier) else { throw CocoaError(.fileReadCorruptFile) }
                try await coordinator.resolveActivity(id)
                callback.value(nil)
            } catch { callback.value(ProviderErrors.translate(error) as NSError) }
        }
    }

    func setMountOffline(_ keep: Bool, reply: @escaping (NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do { try await coordinator.setMountOffline(keep); callback.value(nil) }
            catch { callback.value(ProviderErrors.translate(error) as NSError) }
        }
    }

    func maintainCache(_ bytes: Int64, ageDays: Int, reply: @escaping (Int64, NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do {
                guard bytes >= 0, bytes <= 1_000_000_000_000, [0, 1, 7, 30, 90].contains(ageDays) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard bytes > 0 || ageDays > 0 else { callback.value(0, nil); return }
                let cutoff = ageDays == 0 ? nil : Date().addingTimeInterval(-Double(ageDays) * 86400)
                let result = try await coordinator.freeUpSpace(nil, preservingOffline: true, byteBudget: bytes, olderThan: cutoff)
                callback.value(result.freedBytes, result.failure.map { ProviderErrors.translate($0) as NSError })
            } catch { callback.value(0, ProviderErrors.translate(error) as NSError) }
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

    func clearCache(reply: @escaping (Int, [String], NSError?) -> Void) {
        let callback = ProviderCallback(reply)
        _ = tasks.run { [coordinator] _ in
            do {
                let report = try await coordinator.freeUpSpace(nil, preservingOffline: true)
                callback.value(report.completed, report.retained, report.failure.map { ProviderErrors.translate($0) as NSError })
            } catch {
                callback.value(0, [], ProviderErrors.translate(error) as NSError)
            }
        }
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
