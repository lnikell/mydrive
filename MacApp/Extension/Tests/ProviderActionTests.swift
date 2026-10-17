import Foundation
import FileProvider

private struct ActionTestFailure: Error { let message: String }

private func expectAction(_ condition: Bool, _ message: String) throws {
    if !condition { throw ActionTestFailure(message: message) }
}

private actor ActionCalls {
    struct Call: Sendable, Equatable { let name: String; let identifiers: [String] }
    private(set) var values: [Call] = []
    func record(_ name: String, _ identifiers: [String]) { values.append(Call(name: name, identifiers: identifiers)) }
}

enum ProviderActionTests {
    static func run() async throws -> Int {
        let calls = ActionCalls()
        let handler = ProviderActionHandler(
            keepDownloaded: { await calls.record("keep", $0) },
            freeUpSpace: {
                await calls.record("free", $0)
                return EvictionReport(completed: 2, retained: [], failure: nil)
            })
        try await handler.perform(action: "local.mydrive.keepDownloaded", on: ["first", "first", "second"])
        try await handler.perform(action: "local.mydrive.freeUpSpace", on: ["first", "second"])
        try expectAction(await calls.values == [
            ActionCalls.Call(name: "keep", identifiers: ["first", "second"]),
            ActionCalls.Call(name: "free", identifiers: ["first", "second"])
        ], "Finder actions did not route the complete unique selection")
        print("PASS Finder actions dispatch multiple identifiers without duplicate operations")

        let invalidSelections = [
            [], [""], ["folder/file"], ["bad\0identifier"],
            [NSFileProviderItemIdentifier.workingSet.rawValue],
            [NSFileProviderItemIdentifier.trashContainer.rawValue],
            Array(repeating: "first", count: 1_001)
        ]
        for identifiers in invalidSelections {
            var rejected = false
            do { try await handler.perform(action: "local.mydrive.keepDownloaded", on: identifiers) }
            catch { rejected = true }
            try expectAction(rejected, "Invalid Finder selection reached an offline operation")
        }
        var unknownRejected = false
        do { try await handler.perform(action: "unknown-action", on: ["first"]) }
        catch { unknownRejected = true }
        let invalidCallCount = await calls.values.count
        try expectAction(unknownRejected && invalidCallCount == 2,
                         "Invalid Finder action changed local offline policy")
        print("PASS Finder action identifiers and selection bounds fail before side effects")

        let retained = ["An open file remains downloaded."]
        let failure = CocoaError(.fileReadNoPermission)
        let partial = ProviderActionHandler(keepDownloaded: { _ in }, freeUpSpace: { _ in
            EvictionReport(completed: 3, retained: retained, failure: failure)
        })
        var partialError: NSError?
        do { try await partial.perform(action: "local.mydrive.freeUpSpace", on: ["first"]) }
        catch { partialError = error as NSError }
        try expectAction(partialError?.domain == NSCocoaErrorDomain &&
                         partialError?.userInfo["MyDriveCompletedEvictions"] as? Int == 3 &&
                         partialError?.userInfo["MyDriveRetainedItems"] as? [String] == retained &&
                         (partialError?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == failure.errorCode,
                         "Partial cleanup discarded completed, retained, or failure evidence")
        let retainedOnly = ProviderActionHandler(keepDownloaded: { _ in }, freeUpSpace: { _ in
            EvictionReport(completed: 0, retained: retained, failure: nil)
        })
        var retainedReported = false
        do { try await retainedOnly.perform(action: "local.mydrive.freeUpSpace", on: ["first"]) }
        catch { retainedReported = true }
        try expectAction(retainedReported, "Retained downloads were acknowledged as complete cleanup")
        print("PASS partial Finder cleanup reports completed work, retained files, and underlying failure")

        let started = ActionCalls()
        let cancellable = ProviderActionHandler(keepDownloaded: {
            await started.record("keep", $0)
            try await Task.sleep(for: .seconds(10))
        }, freeUpSpace: { _ in EvictionReport(completed: 0, retained: [], failure: nil) })
        let pending = Task {
            try await cancellable.perform(action: "local.mydrive.keepDownloaded", on: ["first"])
        }
        while (await started.values).isEmpty { await Task.yield() }
        pending.cancel()
        do { try await pending.value; throw ActionTestFailure(message: "Cancelled Finder operation succeeded") }
        catch is CancellationError {}
        let interrupted = ProviderActionHandler(keepDownloaded: { _ in }, freeUpSpace: { _ in
            EvictionReport(completed: 2, retained: retained, failure: CancellationError())
        })
        var cancellation: NSError?
        do { try await interrupted.perform(action: "local.mydrive.freeUpSpace", on: ["first"]) }
        catch { cancellation = error as NSError }
        try expectAction(cancellation?.code == CocoaError.userCancelled.rawValue &&
                         cancellation?.userInfo["MyDriveCompletedEvictions"] as? Int == 2,
                         "Cancellation discarded partial cleanup or used the wrong error")
        print("PASS Finder action cancellation stops work and preserves partial cleanup evidence")
        return 4
    }
}
