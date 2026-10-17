import Foundation
import MyDriveCore

/// One immutable Catalog frontier, drained before selecting any new work.
/// Durable journals and receipts remain owned by the existing import callback.
enum TreeImportFrontier {
    static let workerLimit = 4

    static func perform(_ work: [TreeImportWork], progress: TreeProgressAggregate,
                        operation: @escaping @Sendable (TreeImportWork, TreeWorkProgress) async throws -> Void) async throws {
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            func addNext() throws {
                try Task.checkCancellation()
                let item = work[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    let stepProgress = try progress.begin(expectedBytes: expectedBytes(item))
                    defer { stepProgress.abandon() }
                    try await operation(item, stepProgress)
                    // Operation returns only after its canonical Core receipt.
                    stepProgress.finish()
                }
            }
            do {
                for _ in 0..<min(workerLimit, work.count) { try addNext() }
                while try await group.next() != nil {
                    if nextIndex < work.count { try addNext() }
                }
            } catch {
                group.cancelAll()
                // HelperOperation owns process cancellation/reaping. Do not
                // release the domain gate while any child is still unwinding.
                while !group.isEmpty { _ = try? await group.next() }
                throw error
            }
        }
    }

    private static func expectedBytes(_ work: TreeImportWork) -> Int64? {
        switch work {
        case .mutation(_, let intent, _, _): intent.payload?.size
        case .verifyFile(_, _, let payload): payload.size
        case .verifyDirectory: nil
        }
    }
}
