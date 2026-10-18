import Foundation

/// One registry owns every task until it actually finishes. A closed XPC scope
/// cancels only its requests; those handles remain in the global shutdown drain.
final class ProviderTasks: @unchecked Sendable {
    final class Scope: @unchecked Sendable {
        fileprivate let registry: ProviderTasks
        // Accessed only under registry.lock, together with task registration.
        fileprivate var closed = false
        fileprivate init(_ registry: ProviderTasks) { self.registry = registry }

        func run(_ work: @escaping @Sendable (Progress) async -> Void) -> Progress {
            registry.run(in: self, work)
        }

        func invalidate() { registry.cancel(self) }
    }

    private struct Entry {
        let task: Task<Void, Never>
        let scope: Scope?
    }
    private let lock = NSLock()
    private var tasks: [UUID: Entry] = [:]
    private var invalidated = false

    func makeScope() -> Scope { Scope(self) }

    func run(_ work: @escaping @Sendable (Progress) async -> Void) -> Progress {
        run(in: nil, work)
    }

    private func run(in scope: Scope?, _ work: @escaping @Sendable (Progress) async -> Void) -> Progress {
        let identifier = UUID()
        let progress = Progress(totalUnitCount: 1)
        lock.lock()
        let initiallyCancelled = invalidated || scope?.closed == true
        let task = Task {
            // Rejected requests still deliver their cancellation callback, but
            // cannot pass the operation's cancellation/owner checks to do I/O.
            if initiallyCancelled { withUnsafeCurrentTask { $0?.cancel() } }
            await work(progress)
            self.remove(identifier)
        }
        tasks[identifier] = Entry(task: task, scope: scope)
        if initiallyCancelled { task.cancel() }
        lock.unlock()
        progress.cancellationHandler = { @Sendable in task.cancel() }
        return progress
    }

    @discardableResult
    func invalidate() -> [Task<Void, Never>] {
        lock.lock()
        invalidated = true
        let running = tasks.values.map(\.task)
        // Retain cancelled/draining handles until remove(), including tasks
        // whose own XPC connection has already disappeared.
        lock.unlock()
        running.forEach { $0.cancel() }
        return running
    }

    private func cancel(_ scope: Scope) {
        lock.lock()
        scope.closed = true
        let running = tasks.values.filter { $0.scope === scope }.map(\.task)
        lock.unlock()
        running.forEach { $0.cancel() }
    }

    private func remove(_ identifier: UUID) {
        lock.lock()
        tasks.removeValue(forKey: identifier)
        lock.unlock()
    }
}
