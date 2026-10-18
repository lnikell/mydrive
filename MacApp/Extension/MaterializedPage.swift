import Foundation
import FileProvider
import UniformTypeIdentifiers

/// Enumerate macOS's cache rather than scanning the NAS merely to free space.
/// Only one bounded page of identifiers is retained at a time.
final class MaterializedPage: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    // Materialized-set enumeration requires empty Data, not the initial sorting
    // tokens used for the provider's ordinary directory enumerators.
    static var initialPage: NSFileProviderPage { NSFileProviderPage(Data()) }

    struct Item: Sendable {
        enum Kind: Equatable, Sendable { case leaf, container, unknown }
        let identifier: String
        let kind: Kind

        init(identifier: String, kind: Kind) { self.identifier = identifier; self.kind = kind }

        init(_ item: any NSFileProviderItem) {
            identifier = item.itemIdentifier.rawValue
            // Native representation decides eligibility. A logical package leaf
            // can be backed by a remote directory; no Catalog kind is consulted.
            guard let type = item.contentType, !type.isDynamic else { kind = .unknown; return }
            if type.conforms(to: .folder) { kind = .container }
            else if type.conforms(to: .package) || !type.conforms(to: .directory) { kind = .leaf }
            else { kind = .unknown }
        }
    }

    struct ResultPage: Sendable {
        let items: [Item]
        let next: NSFileProviderPage?
        var identifiers: [String] { items.map(\.identifier) }
    }

    private let lock = NSLock()
    private var items: [Item] = []
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
        guard items.count + updatedItems.count <= suggestedPageSize * 100 else {
            lock.unlock()
            finish(.failure(CocoaError(.fileReadCorruptFile)))
            return
        }
        items.append(contentsOf: updatedItems.map(Item.init))
        lock.unlock()
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        lock.lock()
        let result = ResultPage(items: items, next: nextPage)
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
        items.removeAll()
        lock.unlock()
        waiting?.resume(with: result)
    }
}
