import Foundation
import FileProvider

/// Enumerate macOS's cache rather than scanning the NAS merely to free space.
/// Only one bounded page of identifiers is retained at a time.
final class MaterializedPage: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    struct ResultPage: Sendable {
        let identifiers: [String]
        let next: NSFileProviderPage?
    }

    private let lock = NSLock()
    private var identifiers: [String] = []
    private var outcome: Result<ResultPage, Error>?
    private var continuation: CheckedContinuation<ResultPage, any Error>?
    var suggestedPageSize: Int { 128 }

    static func read(
        from enumerator: any NSFileProviderEnumerator, startingAt page: NSFileProviderPage,
        timeout: Duration = .seconds(30),
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> ResultPage {
        let observer = MaterializedPage()
        let deadline = Task { @Sendable in
            do {
                try await Task.sleep(for: timeout)
                observer.finish(.failure(CocoaError(.fileReadUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "macOS did not finish enumerating its local cache in time."])))
            } catch { /* The page completed or was cancelled. */ }
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if observer.install(continuation) {
                    enumerator.enumerateItems(for: observer, startingAt: page)
                }
            }
        } onCancel: {
            observer.finish(.failure(CancellationError()))
        }
    }

    func didEnumerate(_ updatedItems: [any NSFileProviderItem]) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        // Apple permits at most 100 times the observer's suggested page size.
        guard identifiers.count + updatedItems.count <= suggestedPageSize * 100 else {
            lock.unlock()
            finish(.failure(CocoaError(.fileReadCorruptFile)))
            return
        }
        identifiers.append(contentsOf: updatedItems.map { $0.itemIdentifier.rawValue })
        lock.unlock()
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        lock.lock()
        let result = ResultPage(identifiers: identifiers, next: nextPage)
        lock.unlock()
        finish(.success(result))
    }

    func finishEnumeratingWithError(_ error: any Error) {
        finish(.failure(error))
    }

    private func install(_ continuation: CheckedContinuation<ResultPage, any Error>) -> Bool {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func finish(_ result: Result<ResultPage, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiting = continuation
        continuation = nil
        identifiers.removeAll()
        lock.unlock()
        waiting?.resume(with: result)
    }
}
