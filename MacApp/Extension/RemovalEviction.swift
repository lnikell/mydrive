import FileProvider
import Foundation
import MyDriveCore
import Darwin

/// One streaming cache pass before dirty-preserving domain removal. Memory is
/// page-bounded; cancellation and individual native wait limits bound liveness.
/// macOS alone decides whether an individual native leaf can be evicted.
struct RemovalEviction: Sendable {
    enum Failure: LocalizedError {
        case deadline, repeatedPage
        var errorDescription: String? {
            switch self {
            case .deadline:
                "Local-download cleanup stopped waiting. macOS may still finish an accepted request; remaining local work will be preserved."
            case .repeatedPage:
                "macOS repeated a local-cache enumeration page. Local-download cleanup did not finish."
            }
        }
    }

    let requestTimeout: Duration
    var requestDeadline: ContinuousClock.Instant { ContinuousClock.now.advanced(by: requestTimeout) }

    init(requestTimeout: Duration = .seconds(20)) {
        precondition(requestTimeout > .zero)
        self.requestTimeout = requestTimeout
    }

    /// Explicit selections are paged, rather than walking every cached folder
    /// merely to clear policy. A new pin is still rechecked before each eviction.
    func clearSelections(in catalog: Catalog, checkActive: @Sendable () async throws -> Void) async throws {
        var after: String?
        while true {
            try Task.checkCancellation(); try await checkActive()
            let selections = try await catalog.offlineSelections(afterID: after, limit: 128)
            guard !selections.isEmpty else { return }
            for item in selections {
                try Task.checkCancellation(); try await checkActive()
                try await catalog.setOfflinePolicy(.onDemand, for: item.id)
                after = item.id
            }
        }
    }

    /// Each leaf receives its own bounded policy-settling window, even after a
    /// long scan. Every retry shares that leaf's native-call deadline.
    func evict(
        isKeptDownloaded: @Sendable () async throws -> Bool,
        checkActive: @Sendable () async throws -> Void,
        attempt: @Sendable (ContinuousClock.Instant) async throws -> Void
    ) async throws -> PolicyAwareEviction.Outcome {
        let deadline = requestDeadline
        let retry = PolicyAwareEviction(retryWindow: min(.seconds(5), requestTimeout))
        return try await retry.evict(isKeptDownloaded: isKeptDownloaded, checkActive: checkActive, attempt: {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await attempt(deadline)
        })
    }

    /// Documented item-local OS refusals can be preserved during removal.
    /// Policy/Catalog errors and provider/service failures instead make the pass
    /// incomplete; a matching numeric code in another domain is not a refusal.
    private static func isPerItemRefusal(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSFileProviderErrorDomain {
            return [NSFileProviderError.unsyncedEdits.rawValue, NSFileProviderError.nonEvictable.rawValue,
                    NSFileProviderError.nonEvictableChildren.rawValue].contains(error.code)
        }
        return error.domain == NSPOSIXErrorDomain && [Int(EBUSY), Int(EMLINK)].contains(error.code)
    }

    func run(
        isolation: isolated (any Actor)? = #isolation,
        preparePolicy: () async throws -> Void,
        checkActive: () async throws -> Void,
        readPage: (NSFileProviderPage, Duration) async throws -> MaterializedPage.ResultPage,
        evict: (String) async throws -> PolicyAwareEviction.Outcome
    ) async throws -> EvictionReport {
        var completed = 0
        var retained = 0
        var messages: [String] = []
        func retain(_ reason: String) {
            retained += 1
            if messages.count < 16 { messages.append(String(reason.prefix(240))) }
        }
        func report(_ failure: (any Error)? = nil) -> EvictionReport {
            var result = messages
            if retained > messages.count { result.append("\(retained - messages.count) additional downloads retained.") }
            return EvictionReport(completed: completed, retained: result, failure: failure)
        }
        do {
            try Task.checkCancellation(); try await checkActive()
            try await preparePolicy()
            var page = MaterializedPage.initialPage
            while true {
                try Task.checkCancellation(); try await checkActive()
                let next = try await readPage(page, requestTimeout)
                for item in next.items {
                    try Task.checkCancellation(); try await checkActive()
                    switch item.kind {
                    case .container: continue // Never start recursive folder eviction.
                    case .unknown: retain("A download has an unknown native type and was retained.")
                    case .leaf:
                        do {
                            if try await evict(item.identifier) == .evicted { completed += 1 }
                            else { retain("A download is still kept by an offline selection.") }
                        } catch {
                            try Task.checkCancellation(); try await checkActive()
                            guard Self.isPerItemRefusal(error) else { throw error }
                            retain("A download was retained: " + error.localizedDescription)
                        }
                    }
                }
                guard let continuation = next.next else { return report() }
                guard continuation.rawValue != page.rawValue else { throw Failure.repeatedPage }
                page = continuation
            }
        } catch {
            try Task.checkCancellation(); try await checkActive()
            return report(error)
        }
    }
}
