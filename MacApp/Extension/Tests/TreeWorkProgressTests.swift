import Foundation
import MyDriveCore

enum TreeWorkProgressTests {
    static func run() throws -> Int {
        try aggregateBytesAndReceipts()
        try concurrentAndStaleCallbacks()
        return 2
    }

    private static func configure(_ progress: Progress) throws -> TreeProgressAggregate {
        try TreeWorkProgress.configure(progress,
            tree: .init(id: UUID(), nodeCount: 2, totalBytes: 64, sha256: String(repeating: "a", count: 64)))
    }

    private static func aggregateBytesAndReceipts() throws {
        let progress = Progress(totalUnitCount: 1), aggregate = try configure(progress)
        let upload = try aggregate.begin(expectedBytes: 64)
        upload.received(32)
        let middle = progress.completedUnitCount
        upload.received(64)
        try mutationCheck(middle > 0 && progress.completedUnitCount == 999_999 && !progress.isFinished,
                          "Actual bytes completed a tree step before its verified Core receipt")
        upload.finish(); upload.finish()
        try mutationCheck(progress.completedUnitCount == 1_000_000, "A duplicate finish counted the same receipt twice")
        let empty = try aggregate.begin(expectedBytes: 0)
        empty.received(0)
        try mutationCheck(progress.completedUnitCount == 1_000_000, "An empty file invented pre-commit byte progress")
        empty.finish()
        try mutationCheck(progress.completedUnitCount == 2_000_000 && !progress.isFinished,
                          "A child completed the whole import before its final root receipt")
        print("PASS aggregate byte milestones stay provisional, empty files wait for receipts, duplicate completion is harmless")
    }

    private static func concurrentAndStaleCallbacks() throws {
        let progress = Progress(totalUnitCount: 1), aggregate = try configure(progress)
        let workers = try (0..<4).map { _ in try aggregate.begin(expectedBytes: 1_000) }
        do { _ = try aggregate.begin(expectedBytes: 1); throw MutationTestFailure(message: "Progress retained a fifth active token") }
        catch is MutationTestFailure { throw MutationTestFailure(message: "Progress retained a fifth active token") } catch {}
        DispatchQueue.concurrentPerform(iterations: 4_000) { index in
            workers[index % 4].received(Int64(index / 4 + 1))
        }
        try mutationCheck(progress.completedUnitCount == 3_999_996,
                          "Concurrent bytes lost one worker's contribution or exceeded its provisional milestone")
        let highWater = progress.completedUnitCount
        workers[3].finish(); workers[0].abandon(); workers[1].abandon(); workers[2].finish()
        for worker in workers { worker.received(Int64.max); worker.finish(); worker.abandon() }
        try mutationCheck(progress.completedUnitCount >= highWater && progress.completedUnitCount < progress.totalUnitCount,
                          "Out-of-order/stale callbacks regressed or falsely finished root progress")
        let replacement = try aggregate.begin(expectedBytes: 1)
        replacement.received(1); replacement.finish()
        try mutationCheck(progress.completedUnitCount >= highWater && !progress.isFinished,
                          "Released token capacity was not reusable without a retained per-node progress graph")
        print("PASS four concurrent counters aggregate exactly; stale callbacks, failed siblings and reverse receipts cannot regress progress")
    }
}
