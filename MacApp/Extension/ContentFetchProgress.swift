import Foundation

/// Received bytes are provisional until the fetched version and staging file
/// pass validation. Reserve completion for that successful handoff.
struct ContentFetchProgress: Sendable {
    private let progress: Progress
    private let total: Int64

    init(_ progress: Progress, expectedBytes: Int64) {
        self.progress = progress
        total = max(1, expectedBytes)
        progress.totalUnitCount = total
        progress.completedUnitCount = 0
    }

    func received(_ bytes: Int64) {
        progress.completedUnitCount = min(max(0, bytes), total - 1)
    }

    func finish(validating validation: () throws -> Void) rethrows {
        try validation()
        progress.completedUnitCount = total
    }
}
