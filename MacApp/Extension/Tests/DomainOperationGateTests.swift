import Foundation

private actor GateOrder {
    var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

enum DomainOperationGateTests {
    static func run() async throws -> Int {
        let gate = DomainOperationGate()
        let holder = try await gate.acquire()
        let order = GateOrder()
        let first = Task {
            try await gate.perform { await order.append(1) }
        }
        while await gate.pendingCount < 1 { await Task.yield() }
        let cancelled = Task {
            try await gate.perform { await order.append(99) }
        }
        while await gate.pendingCount < 2 { await Task.yield() }
        let last = Task {
            try await gate.perform { await order.append(2) }
        }
        while await gate.pendingCount < 3 { await Task.yield() }
        cancelled.cancel()
        do { try await cancelled.value; throw CocoaError(.fileLocking) }
        catch is CancellationError {}
        await gate.release(holder)
        try await first.value; try await last.value
        guard await order.values == [1, 2] else { throw CocoaError(.fileLocking) }
        print("PASS domain FIFO serializes writes/listings and removes a cancelled waiter without reordering")

        let finalHolder = try await gate.acquire()
        let pending = Task { try await gate.acquire() }
        while await gate.pendingCount == 0 { await Task.yield() }
        await gate.close()
        do { _ = try await pending.value; throw CocoaError(.fileLocking) }
        catch is CancellationError {}
        await gate.release(finalHolder)
        do { _ = try await gate.acquire(); throw CocoaError(.fileLocking) }
        catch is CancellationError {}
        print("PASS invalidation cancels gate waiters and prevents a replacement operation from starting")
        return 2
    }
}
