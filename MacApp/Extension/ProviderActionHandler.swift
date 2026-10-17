import Foundation
import FileProvider

/// Finder supplies identifiers; the domain owner performs the same operations
/// used by the app. This adapter also preserves partial cleanup results.
struct ProviderActionHandler: Sendable {
    enum Action: String {
        case keepDownloaded = "local.mydrive.keepDownloaded"
        case freeUpSpace = "local.mydrive.freeUpSpace"
    }

    private let keepDownloaded: @Sendable ([String]) async throws -> Void
    private let freeUpSpace: @Sendable ([String]) async throws -> EvictionReport

    init(coordinator: DomainCoordinator) {
        self.init(
            keepDownloaded: { try await coordinator.keepDownloaded($0) },
            freeUpSpace: { try await coordinator.freeUpSpace($0) })
    }

    init(
        keepDownloaded: @escaping @Sendable ([String]) async throws -> Void,
        freeUpSpace: @escaping @Sendable ([String]) async throws -> EvictionReport
    ) {
        self.keepDownloaded = keepDownloaded
        self.freeUpSpace = freeUpSpace
    }

    func perform(action identifier: String, on identifiers: [String]) async throws {
        try Task.checkCancellation()
        guard let action = Action(rawValue: identifier) else { throw CocoaError(.featureUnsupported) }
        guard !identifiers.isEmpty, identifiers.count <= 1_000,
              identifiers.allSatisfy({
                  !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") &&
                  $0 != NSFileProviderItemIdentifier.workingSet.rawValue &&
                  $0 != NSFileProviderItemIdentifier.trashContainer.rawValue
              }) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "Choose between 1 and 1,000 NAS files or folders."])
        }
        var seen: Set<String> = []
        let selected = identifiers.filter { seen.insert($0).inserted }
        switch action {
        case .keepDownloaded:
            try await keepDownloaded(selected)
        case .freeUpSpace:
            let report = try await freeUpSpace(selected)
            if let error = Self.cleanupError(report, cancelled: Task.isCancelled) { throw error }
        }
        try Task.checkCancellation()
    }

    private static func cleanupError(_ report: EvictionReport, cancelled: Bool) -> NSError? {
        let underlying = report.failure.map { ProviderErrors.translate($0) as NSError }
        let wasCancelled = cancelled || (underlying?.domain == NSCocoaErrorDomain &&
            underlying?.code == CocoaError.userCancelled.rawValue)
        guard wasCancelled || underlying != nil || !report.retained.isEmpty else { return nil }
        let count = report.completed
        let freed = "\(count) \(count == 1 ? "file" : "files") freed."
        var details: [String: Any] = [
            NSLocalizedDescriptionKey: wasCancelled
                ? "Free Up Space was cancelled. \(freed)"
                : "\(freed) Some downloads could not be removed.",
            "MyDriveCompletedEvictions": count,
            "MyDriveRetainedItems": report.retained
        ]
        if !report.retained.isEmpty {
            details[NSLocalizedFailureReasonErrorKey] = report.retained.joined(separator: "\n")
        }
        if let underlying { details[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: NSCocoaErrorDomain,
                       code: wasCancelled ? CocoaError.userCancelled.rawValue : CocoaError.fileWriteUnknown.rawValue,
                       userInfo: details)
    }
}
