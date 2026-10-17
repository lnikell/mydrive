import Foundation
import FileProvider
import MyDriveCore

enum ProviderErrors {
    static func noSuchItem() -> Error { NSFileProviderError(.noSuchItem) }
    static func expiredPage() -> Error { NSFileProviderError(.pageExpired) }
    static func readOnly() -> Error { CocoaError(.fileWriteNoPermission) }

    static func translate(_ error: Error) -> Error {
        if error is CancellationError { return CocoaError(.userCancelled) }
        if let error = error as? CapturedDeletionConflict { return MutationInput.unsupported(error.message) }
        if let error = error as? MutationParentError {
            switch error {
            case .refreshRequired:
                return CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "This NAS folder needs to finish refreshing before the change can be sent. Local changes are preserved."])
            case .replaced:
                return MutationInput.unsupported("This NAS folder's identity could not be verified. Local changes are preserved; refresh the folder before trying again.")
            }
        }
        if let error = error as? CredentialStoreError {
            switch error {
            case .loginKeychainLocked: return NSFileProviderError(.notAuthenticated)
            }
        }
        if let error = error as? SMBClientError {
            switch error {
            case .authenticationRequired: return NSFileProviderError(.notAuthenticated)
            case .serverUnreachable: return NSFileProviderError(.serverUnreachable)
            case .cancelled: return CocoaError(.userCancelled)
            case .invalidResponse: return CocoaError(.fileReadCorruptFile)
            case .permissionDenied: return CocoaError(.fileReadNoPermission)
            case .itemMissing: return noSuchItem()
            case .diskFull: return CocoaError(.fileWriteOutOfSpace)
            case .changed: return NSFileProviderError(.versionNoLongerAvailable)
            case .unsupportedFeature: return CocoaError(.featureUnsupported)
            case .scopeChanged: return MutationInput.unsupported("The selected folder moved or was replaced. Remaining items and recovery records are preserved.")
            case .localFailure, .remoteFailure: break
            }
        }
        if error is ChangeFeedError { return NSFileProviderError(.syncAnchorExpired) }
        if let error = error as? CatalogError {
            switch error {
            case .missingItem, .invalidParent: return noSuchItem()
            case .invalidCursor, .staleCursor: return expiredPage()
            default: break
            }
        }
        if error is NSFileProviderError || (error as NSError).domain == NSCocoaErrorDomain {
            return error
        }
        return NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.Code.xpcConnectionReplyInvalid.rawValue,
            userInfo: [NSUnderlyingErrorKey: error])
    }
}

/// Objective-C framework observers/completions are only used by one operation.
/// The box transfers that ownership to the operation's task without asserting
/// that arbitrary File Provider objects are generally safe to share.
final class ProviderCallback<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Cancellation has one owner and applies to in-flight tasks on invalidation.
final class ProviderTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var invalidated = false

    func run(_ work: @escaping @Sendable (Progress) async -> Void) -> Progress {
        let identifier = UUID()
        let progress = Progress(totalUnitCount: 1)
        // Keep registration atomic with task startup. A completed task cannot
        // remove its record before it has been stored.
        lock.lock()
        let initiallyCancelled = invalidated
        let task = Task {
            if initiallyCancelled { withUnsafeCurrentTask { $0?.cancel() } }
            await work(progress)
            self.remove(identifier)
        }
        tasks[identifier] = task
        if invalidated { task.cancel() }
        lock.unlock()
        progress.cancellationHandler = { @Sendable in task.cancel() }
        return progress
    }

    @discardableResult
    func invalidate() -> [Task<Void, Never>] {
        lock.lock()
        invalidated = true
        let running = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        running.forEach { $0.cancel() }
        return running
    }

    private func remove(_ identifier: UUID) {
        lock.lock()
        tasks.removeValue(forKey: identifier)
        lock.unlock()
    }
}
