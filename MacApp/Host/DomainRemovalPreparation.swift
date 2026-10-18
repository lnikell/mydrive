import Foundation

/// Per-item eviction refusals preserve work. An incomplete cache pass stops
/// before credentials/domain removal so the connected drive can be retried.
/// This owns the ordering before the provider's credentials/endpoint disappear.
@MainActor enum DomainRemovalPreparation {
    struct Result {
        let preservedURL: URL?
        let warnings: [String]
    }

    static func cacheWarnings(retained: [String], failure: NSError?) throws -> [String] {
        if let failure { try checkCancellation(failure) }
        let warnings = retained.prefix(17).map { String($0.prefix(320)) }
        if let failure {
            var details = failure.userInfo
            details[NSUnderlyingErrorKey] = failure
            details["MyDriveCleanupFailures"] = warnings
            throw NSError(domain: failure.domain, code: failure.code, userInfo: details)
        }
        return warnings
    }

    static func run(
        prepareCache: () async throws -> [String],
        forgetCredential: () async throws -> Void,
        removeDomain: () async throws -> URL?
    ) async throws -> Result {
        var warnings: [String] = []
        try Task.checkCancellation()
        do { warnings += try await prepareCache().prefix(18).map { String($0.prefix(320)) } }
        catch {
            try checkCancellation(error)
            let failure = error as NSError
            var details = failure.userInfo
            details[NSLocalizedDescriptionKey] = "Local-download cleanup did not finish. The drive is still connected; try again.\n" +
                String(failure.localizedDescription.prefix(400))
            details[NSUnderlyingErrorKey] = failure
            throw NSError(domain: failure.domain, code: failure.code, userInfo: details)
        }
        try Task.checkCancellation()
        do { try await forgetCredential() }
        catch {
            try checkCancellation(error)
            warnings.append("Provider development credentials: " + String(error.localizedDescription.prefix(320)))
        }
        try Task.checkCancellation()
        do {
            // Do not check cancellation after this commit: the caller must keep
            // and record any dirty-data export even if cancellation raced removal.
            return Result(preservedURL: try await removeDomain(), warnings: warnings)
        } catch {
            guard !warnings.isEmpty else { throw error }
            let failure = error as NSError
            var details = failure.userInfo
            details[NSLocalizedDescriptionKey] = failure.localizedDescription +
                "\nRemoval preparation also needs attention: " + warnings.joined(separator: "\n")
            details[NSUnderlyingErrorKey] = failure
            details["MyDriveCleanupFailures"] = warnings
            throw NSError(domain: failure.domain, code: failure.code, userInfo: details)
        }
    }

    private static func checkCancellation(_ error: any Error) throws {
        try Task.checkCancellation()
        let native = error as NSError
        if error is CancellationError ||
            (native.domain == NSCocoaErrorDomain && native.code == CocoaError.userCancelled.rawValue) {
            throw CancellationError()
        }
    }
}
