import FileProvider
import Foundation

private enum RemovalOrderFailure: Error { case failed(String) }

@main @MainActor struct DomainRemovalPreparationTests {
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw RemovalOrderFailure.failed(message) }
    }

    static func main() async throws {
        try await successAndWarnings()
        try await incompletePassStops()
        try await failedRemovalKeepsCauses()
        try await cancellationBoundaries()
        try await committedExportSurvivesCancellation()
        print("PASS 5 domain removal preparation groups")
    }

    private static func successAndWarnings() async throws {
        let export = URL(fileURLWithPath: "/retained-work")
        var events: [String] = []
        let result = try await DomainRemovalPreparation.run(prepareCache: {
            events.append("evict"); return ["An open download was retained."]
        }, forgetCredential: { events.append("forget") }, removeDomain: {
            events.append("preserveDirty"); return export
        })
        try check(events == ["evict", "forget", "preserveDirty"] && result.preservedURL == export && result.warnings.count == 1,
                  "Removal ordering, native export or retained warning changed")
        events.removeAll()
        let failedPreparation = try await DomainRemovalPreparation.run(prepareCache: {
            events.append("evict")
            return try DomainRemovalPreparation.cacheWarnings(retained: ["macOS retained an unsynced download."], failure: nil)
        }, forgetCredential: {
            events.append("forget"); throw CocoaError(.fileWriteNoPermission)
        }, removeDomain: { events.append("preserveDirty"); return export })
        try check(events == ["evict", "forget", "preserveDirty"] && failedPreparation.warnings.count == 2 &&
                  failedPreparation.preservedURL == export, "Best-effort failures prevented dirty-preserving removal or vanished")
        print("PASS eviction precedes credential forget/removal and per-item refusals preserve exports plus warnings")
    }

    private static func incompletePassStops() async throws {
        for (cacheReply, original) in [(false, CocoaError(.fileReadUnknown) as NSError),
                                     (true, CocoaError(.fileReadUnknown) as NSError),
                                     (true, NSFileProviderError(.providerNotFound) as NSError)] {
            var events: [String] = []
            do {
                _ = try await DomainRemovalPreparation.run(prepareCache: {
                    events.append("evict")
                    if cacheReply {
                        return try DomainRemovalPreparation.cacheWarnings(retained: ["An earlier busy item remains."], failure: original)
                    }
                    throw original // Service/transport failure before a complete provider reply.
                }, forgetCredential: { events.append("forget") }, removeDomain: { events.append("remove"); return nil })
                throw RemovalOrderFailure.failed("Incomplete eviction allowed domain removal")
            } catch is RemovalOrderFailure { throw RemovalOrderFailure.failed("Incomplete eviction allowed domain removal") }
            catch {
                let failure = error as NSError
                try check(events == ["evict"] && failure.domain == original.domain && failure.code == original.code &&
                          failure.localizedDescription.contains("still connected"),
                          "Incomplete eviction changed native cause or forgot credentials/removed the connection")
                if cacheReply {
                    try check((failure.userInfo["MyDriveCleanupFailures"] as? [String])?.count == 1,
                              "Incomplete eviction lost an already-retained item's diagnostic")
                }
            }
        }
        print("PASS incomplete enumeration/native timeout/transport failure blocks credential forget and domain removal")
    }

    private static func failedRemovalKeepsCauses() async throws {
        let original = NSFileProviderError(.providerNotFound) as NSError
        do {
            _ = try await DomainRemovalPreparation.run(prepareCache: { ["Busy download retained."] },
                forgetCredential: { throw CocoaError(.fileReadNoPermission) }, removeDomain: { throw original })
            throw RemovalOrderFailure.failed("Failed OS removal returned success")
        } catch is RemovalOrderFailure { throw RemovalOrderFailure.failed("Failed OS removal returned success") }
        catch {
            let failure = error as NSError
            let cause = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            let warnings = failure.userInfo["MyDriveCleanupFailures"] as? [String]
            try check(failure.domain == original.domain && failure.code == original.code &&
                      cause?.domain == original.domain && cause?.code == original.code && warnings?.count == 2,
                      "Removal failure lost native classification or earlier preparation diagnostics")
        }
        print("PASS hard domain-removal failure retains native cause and preceding cleanup errors")
    }

    private static func cancellationBoundaries() async throws {
        for phase in ["before", "evict", "forget", "nativeEvictCancel", "nativeForgetCancel"] {
            var events: [String] = []
            let operation = Task { @MainActor in
                if phase == "before" { withUnsafeCurrentTask { $0?.cancel() } }
                return try await DomainRemovalPreparation.run(prepareCache: {
                    events.append("evict")
                    if phase == "evict" { withUnsafeCurrentTask { $0?.cancel() } }
                    if phase == "nativeEvictCancel" {
                        return try DomainRemovalPreparation.cacheWarnings(retained: ["An earlier download remains."],
                            failure: CocoaError(.userCancelled) as NSError)
                    }
                    return []
                }, forgetCredential: {
                    events.append("forget")
                    if phase == "forget" { withUnsafeCurrentTask { $0?.cancel() } }
                    if phase == "nativeForgetCancel" { throw CocoaError(.userCancelled) }
                }, removeDomain: { events.append("remove"); return nil })
            }
            do { _ = try await operation.value; throw RemovalOrderFailure.failed("Cancellation returned success at \(phase)") }
            catch is CancellationError { }
            try check(!events.contains("remove"), "Cancellation started native domain removal at \(phase)")
            if phase == "before" { try check(events.isEmpty, "Pre-cancelled removal started preparation") }
            if phase == "evict" || phase == "nativeEvictCancel" {
                try check(events == ["evict"], "Cancelled eviction still forgot credentials")
            }
        }
        print("PASS cancellation before/after credential forget never starts domain removal")
    }

    private static func committedExportSurvivesCancellation() async throws {
        let export = URL(fileURLWithPath: "/committed-export")
        let operation = Task { @MainActor in
            try await DomainRemovalPreparation.run(prepareCache: { [] }, forgetCredential: {}, removeDomain: {
                withUnsafeCurrentTask { $0?.cancel() }
                return export
            })
        }
        let result = try await operation.value
        try check(result.preservedURL == export, "Post-commit cancellation hid macOS's retained-work export")
        print("PASS a successful native removal always returns its retained-work export")
    }
}
