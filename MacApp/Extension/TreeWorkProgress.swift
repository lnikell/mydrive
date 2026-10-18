import Foundation
import MyDriveCore

/// One milestone token. Actual bytes stay provisional until its Core receipt.
struct TreeWorkProgress: Sendable {
    private let aggregate: TreeProgressAggregate
    private let id: UUID
    private var observer: (@Sendable (Int64) -> Void)?

    fileprivate init(aggregate: TreeProgressAggregate, id: UUID) {
        self.aggregate = aggregate; self.id = id
    }

    static func configure(_ progress: Progress, tree: StagedTreeReference) throws -> TreeProgressAggregate {
        try TreeProgressAggregate(progress, tree: tree)
    }

    func received(_ bytes: Int64) {
        guard !Task.isCancelled else { return }
        aggregate.received(bytes, id: id)
        observer?(bytes)
    }

    func observing(_ observer: @escaping @Sendable (Int64) -> Void) -> Self {
        var result = self; result.observer = observer; return result
    }

    func finish() { aggregate.finish(id) }
    func abandon() { aggregate.abandon(id) }
}

/// One lock owns all root Progress writes. At most eight active tokens are kept;
/// completed work is a scalar, so memory does not grow with the manifest.
final class TreeProgressAggregate: @unchecked Sendable {
    private struct Slot { let expected: Int64?; var provisional: Int64 = 0 }
    private static let unit: Int64 = 1_000_000
    private let lock = NSLock()
    private let progress: Progress
    private var completed: Int64 = 0
    private var active: [UUID: Slot] = [:]

    init(_ progress: Progress, tree: StagedTreeReference) throws {
        let (steps, firstOverflow) = tree.nodeCount.multipliedReportingOverflow(by: 3)
        // Arena creation also creates/places the root node: layout 2 has
        // exactly three milestones per node, including the final root rename.
        let (units, thirdOverflow) = steps.multipliedReportingOverflow(by: Self.unit)
        let (total, finalOverflow) = units.addingReportingOverflow(1)
        guard tree.nodeCount > 0, !firstOverflow, !thirdOverflow, !finalOverflow, total > 0 else {
            throw CocoaError(.fileReadTooLarge)
        }
        self.progress = progress
        progress.totalUnitCount = total; progress.completedUnitCount = 0
    }

    func begin(expectedBytes: Int64?) throws -> TreeWorkProgress {
        lock.lock(); defer { lock.unlock() }
        guard active.count < TreeImportFrontier.maximumWorkerLimit else { throw CocoaError(.fileReadCorruptFile) }
        let id = UUID(); active[id] = Slot(expected: expectedBytes)
        return TreeWorkProgress(aggregate: self, id: id)
    }

    fileprivate func received(_ bytes: Int64, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard var slot = active[id], let expected = slot.expected, expected > 0, bytes >= 0 else { return }
        let fraction = min(Double(bytes) / Double(expected), 1)
        slot.provisional = max(slot.provisional, min(Int64(fraction * Double(Self.unit)), Self.unit - 1))
        active[id] = slot; publish()
    }

    fileprivate func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard active.removeValue(forKey: id) != nil else { return }
        completed += Self.unit; publish()
    }

    fileprivate func abandon(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        active.removeValue(forKey: id)
        // Failed workers' acknowledged bytes remain a high-water mark. They
        // never count as a committed step or move another worker backwards.
        publish()
    }

    private func publish() {
        let provisional = active.values.reduce(Int64(0)) { $0 + $1.provisional }
        progress.completedUnitCount = max(progress.completedUnitCount,
            min(completed + provisional, progress.totalUnitCount - 1))
    }
}
