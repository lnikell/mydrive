import FileProvider
import Foundation
import MyDriveCore

struct DeletionRequestContext: Sendable {
    let recursive: Bool
    let archive: Data?
    let issuedContextID: UUID?
}

/// Apple documents domain versions as immutable. The lock protects replacement
/// of that reference and its durable metadata; no framework object crosses an
/// async boundary. Only the synchronous NSFileProviderDomainState getter exposes
/// the immutable object itself.
final class DomainVersionSnapshot: @unchecked Sendable {
    static let archiveLimit = 32_768
    static let unavailable = DomainVersionSnapshot()
    private let lock = NSLock()
    private var native: NSFileProviderDomainVersion
    private var state: CatalogDomainVersionState?

    private init() { native = NSFileProviderDomainVersion() }

    init(_ state: CatalogDomainVersionState) throws {
        guard state.epoch >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        native = try Self.decode(state.archive)
        self.state = state
    }

    var domainVersion: NSFileProviderDomainVersion { lock.withLock { native } }
    var durableState: CatalogDomainVersionState? { lock.withLock { state } }

    static func initialArchive() throws -> Data {
        try encode(NSFileProviderDomainVersion())
    }

    /// Capture the OS event version synchronously in its callback. Encoding is
    /// transport/storage only: differently encoded equal versions resolve alike.
    static func archive(_ version: NSFileProviderDomainVersion?) throws -> Data? {
        guard let version else { return nil }
        return try encode(version)
    }

    private static func encode(_ version: NSFileProviderDomainVersion) throws -> Data {
        let data = try NSKeyedArchiver.archivedData(withRootObject: version, requiringSecureCoding: true)
        guard !data.isEmpty, data.count <= archiveLimit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    func nextCheckpoint() throws -> CatalogDomainVersionCheckpoint {
        try lock.withLock {
            guard let state, state.epoch < Int64.max else { throw CocoaError(.fileReadCorruptFile) }
            return CatalogDomainVersionCheckpoint(expectedEpoch: state.epoch, nextArchive: try Self.encode(native.next()))
        }
    }

    /// Call only with the state returned by the durable Core transaction. It is
    /// safe to recover a missed in-process publication by applying a later epoch.
    func publishCommitted(_ committed: CatalogDomainVersionState) throws {
        guard committed.epoch >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let version = try Self.decode(committed.archive)
        try lock.withLock {
            if let state {
                guard committed.epoch >= state.epoch else { throw CocoaError(.fileReadCorruptFile) }
                if committed.epoch == state.epoch {
                    guard committed.contextID == state.contextID, version == native else { throw CocoaError(.fileReadCorruptFile) }
                } else if version <= native { throw CocoaError(.fileReadCorruptFile) }
            }
            native = version
            state = committed
        }
    }

    /// Issued epochs are ordered and immutable. Resolve the OS value with public
    /// Comparable semantics, using logarithmically many bounded SQLite rows.
    /// Nil and old unknown versions deliberately carry no new-scope authority.
    func resolve(_ archive: Data?, recursive: Bool,
                 lookup: @Sendable (Int64) async throws -> CatalogDomainVersionState?) async throws -> DeletionRequestContext {
        try Task.checkCancellation()
        guard let archive else { return DeletionRequestContext(recursive: recursive, archive: nil, issuedContextID: nil) }
        guard let current = durableState else { throw CocoaError(.fileReadCorruptFile) }
        let comparison = try Self.compare(archive, current.archive)
        if comparison == .orderedDescending {
            throw NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue,
                userInfo: [NSLocalizedDescriptionKey:
                    "The deletion request refers to a drive state that this provider has not issued. Local changes are preserved."])
        }
        if comparison == .orderedSame {
            return DeletionRequestContext(recursive: recursive, archive: archive, issuedContextID: current.contextID)
        }
        var lower: Int64 = 0
        var upper = current.epoch
        while lower <= upper {
            try Task.checkCancellation()
            let middle = lower + (upper - lower) / 2
            guard let candidate = try await lookup(middle), candidate.epoch == middle else { throw CocoaError(.fileReadCorruptFile) }
            try Task.checkCancellation()
            switch try Self.compare(archive, candidate.archive) {
            case .orderedSame:
                return DeletionRequestContext(recursive: recursive, archive: archive, issuedContextID: candidate.contextID)
            case .orderedAscending: upper = middle - 1
            case .orderedDescending:
                guard middle < Int64.max else { throw CocoaError(.fileReadCorruptFile) }
                lower = middle + 1
            }
        }
        return DeletionRequestContext(recursive: recursive, archive: archive, issuedContextID: nil)
    }

    private static func compare(_ left: Data, _ right: Data) throws -> ComparisonResult {
        let lhs = try decode(left), rhs = try decode(right)
        return lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func decode(_ data: Data) throws -> NSFileProviderDomainVersion {
        guard !data.isEmpty, data.count <= archiveLimit else { throw CocoaError(.fileReadCorruptFile) }
        do {
            guard let version = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSFileProviderDomainVersion.self, from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return version
        } catch { throw CocoaError(.fileReadCorruptFile) }
    }
}
