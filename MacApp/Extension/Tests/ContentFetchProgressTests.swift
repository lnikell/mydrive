import FileProvider
import Foundation

private struct ContentProgressTestFailure: Error { let message: String }

enum ContentFetchProgressTests {
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw ContentProgressTestFailure(message: message) }
    }

    static func run() throws -> Int {
        let progress = Progress(totalUnitCount: 1)
        let transfer = ContentFetchProgress(progress, expectedBytes: 100)
        transfer.received(23)
        try check(progress.completedUnitCount == 23 && !progress.isFinished,
                  "Real intermediate byte progress was lost")
        transfer.received(100)
        transfer.received(Int64.max)
        try check(progress.completedUnitCount == 99 && progress.fractionCompleted < 1 && !progress.isFinished,
                  "Unvalidated bytes completed the fetch")
        var validated = false
        try transfer.finish {
            try check(!progress.isFinished, "Fetch completed before validation began")
            validated = true
        }
        try check(validated && progress.completedUnitCount == 100 && progress.isFinished,
                  "Successful validation did not complete the fetch")
        print("PASS byte progress remains provisional until content validation succeeds")

        let failures: [Error] = [NSFileProviderError(.versionNoLongerAvailable),
                                 CocoaError(.fileReadCorruptFile), CancellationError()]
        for expected in failures {
            let progress = Progress(totalUnitCount: 1)
            let transfer = ContentFetchProgress(progress, expectedBytes: 100)
            transfer.received(100)
            do {
                try transfer.finish { throw expected }
                throw ContentProgressTestFailure(message: "Failed validation returned success")
            } catch let actual as ContentProgressTestFailure { throw actual }
            catch {
                let actual = error as NSError
                let expected = expected as NSError
                try check(actual.domain == expected.domain && actual.code == expected.code,
                          "Progress finalization changed the validation failure")
                try check(!progress.isFinished && progress.completedUnitCount < progress.totalUnitCount,
                          "Version, corruption or cancellation failure reported completed progress")
            }
        }
        print("PASS content validation failures and cancellation never report a finished fetch")

        for size: Int64 in [0, 1] {
            let progress = Progress(totalUnitCount: 1)
            let transfer = ContentFetchProgress(progress, expectedBytes: size)
            transfer.received(size)
            try check(progress.totalUnitCount == 1 && progress.completedUnitCount == 0 && !progress.isFinished,
                      "Empty or one-byte fetch completed before validation")
            transfer.finish {}
            try check(progress.completedUnitCount == 1 && progress.isFinished,
                      "Empty or one-byte validated fetch never finished")
        }
        print("PASS empty and one-byte files retain a distinct validation completion")
        return 3
    }
}
