import Foundation

/// One FIFO bounds active file-transfer helpers across the Connections served
/// by this process. Finder still schedules callbacks and owns pending work.
actor TransferConcurrency {
    static let shared = TransferConcurrency()
    private var active: Set<UUID> = []
    private var waiters: [(UUID, CheckedContinuation<UUID, Error>)] = []
    private var maximum = 4
    var pendingCount: Int { waiters.count }

    func acquire(limit: Int) async throws -> UUID {
        try Task.checkCancellation()
        guard (1...8).contains(limit) else { throw CocoaError(.fileReadCorruptFile) }
        maximum = limit
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)); drain() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        drain()
    }

    func perform<Value: Sendable>(limit: Int, _ operation: @Sendable () async throws -> Value) async throws -> Value {
        let token = try await acquire(limit: limit)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(token)
            return result
        } catch { release(token); throw error }
    }

    private func drain() {
        while active.count < maximum && !waiters.isEmpty {
            let (id, continuation) = waiters.removeFirst()
            active.insert(id); continuation.resume(returning: id)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        let (_, continuation) = waiters.remove(at: index)
        continuation.resume(throwing: CancellationError())
    }
}
