import Foundation

/// One FIFO covers remote listing publication and namespace mutations. Actor
/// isolation alone does not serialize operations across their network awaits.
actor DomainOperationGate {
    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<UUID, Error>)] = []
    private var closed = false

    var pendingCount: Int { waiters.count }

    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if closed || Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if owner == nil { owner = id; continuation.resume(returning: id) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        if waiters.isEmpty { owner = nil }
        else {
            let (next, continuation) = waiters.removeFirst()
            owner = next; continuation.resume(returning: next)
        }
    }

    func perform<Value: Sendable>(_ work: @Sendable () async throws -> Value) async throws -> Value {
        let token = try await acquire()
        do {
            try Task.checkCancellation()
            let value = try await work()
            release(token)
            return value
        } catch {
            release(token)
            throw error
        }
    }

    func close() {
        closed = true
        let pending = waiters; waiters.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        let (_, continuation) = waiters.remove(at: index)
        continuation.resume(throwing: CancellationError())
    }
}
