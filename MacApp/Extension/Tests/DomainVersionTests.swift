import FileProvider
import Foundation
import MyDriveCore

private actor IssuedVersions {
    let rows: [Int64: CatalogDomainVersionState]
    private(set) var reads = 0
    init(_ rows: [CatalogDomainVersionState]) { self.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.epoch, $0) }) }
    func lookup(_ epoch: Int64) -> CatalogDomainVersionState? { reads += 1; return rows[epoch] }
}

enum DomainVersionTests {
    private static func require(_ value: Bool) throws {
        if !value { throw CocoaError(.fileReadCorruptFile) }
    }

    static func run() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try DomainVersionSnapshot.initialArchive()
        let catalog = try Catalog(databaseURL: root.appendingPathComponent("catalog.sqlite"), initialDomainVersionArchive: initial)
        let first = catalog.initialDomainVersionState!
        let snapshot = try DomainVersionSnapshot(first)
        let checkpoint = try snapshot.nextCheckpoint()
        try require(checkpoint.expectedEpoch == 0 && snapshot.domainVersion == DomainVersionSnapshot.unavailable.domainVersion)
        let reopened = try Catalog(databaseURL: root.appendingPathComponent("catalog.sqlite"), initialDomainVersionArchive: checkpoint.nextArchive)
        let restored = try DomainVersionSnapshot(reopened.initialDomainVersionState!)
        try require(restored.durableState?.contextID == first.contextID && restored.domainVersion == snapshot.domainVersion)
        print("PASS native domain version bootstrap survives restart and an uncommitted next candidate never advances the OS getter")

        var version = NSFileProviderDomainVersion()
        var rows: [CatalogDomainVersionState] = []
        var alternate: Data?
        for epoch in 0...127 {
            if epoch == 64 {
                let encoder = NSKeyedArchiver(requiringSecureCoding: true)
                encoder.outputFormat = .xml
                encoder.encode(version, forKey: NSKeyedArchiveRootObjectKey)
                encoder.finishEncoding()
                alternate = encoder.encodedData
            }
            rows.append(CatalogDomainVersionState(epoch: Int64(epoch), contextID: UUID(),
                archive: try DomainVersionSnapshot.archive(version)!))
            version = version.next()
        }
        let clock = try DomainVersionSnapshot(rows.last!)
        let issued = IssuedVersions(rows)
        let resolved = try await clock.resolve(alternate, recursive: true) { await issued.lookup($0) }
        try require(alternate != rows[64].archive && resolved.issuedContextID == rows[64].contextID && resolved.recursive)
        try require(await issued.reads <= 8)
        let repeatContext = try await DomainVersionSnapshot(rows.last!).resolve(rows[64].archive, recursive: true) { await issued.lookup($0) }
        try require(repeatContext.issuedContextID == resolved.issuedContextID)
        print("PASS differently encoded equal request versions resolve to the same durable UUID with logarithmically bounded lookup")

        let next = try clock.nextCheckpoint()
        let committed = CatalogDomainVersionState(epoch: 128, contextID: UUID(), archive: next.nextArchive)
        let previous = clock.domainVersion
        try clock.publishCommitted(committed)
        try require(previous < clock.domainVersion)
        try clock.publishCommitted(committed)
        do { try clock.publishCommitted(rows[127]); throw CocoaError(.fileWriteUnknown) }
        catch let error as CocoaError where error.code == .fileReadCorruptFile {}
        let restarted = try DomainVersionSnapshot(committed)
        try require(restarted.domainVersion == clock.domainVersion && restarted.durableState?.contextID == committed.contextID)
        print("PASS committed version publication is monotonic, idempotent and restores its issued context across owner replacement")

        let nilContext = try await clock.resolve(nil, recursive: true) { _ in throw CocoaError(.fileReadUnknown) }
        try require(nilContext.issuedContextID == nil && nilContext.archive == nil)
        let future = try DomainVersionSnapshot.archive(clock.domainVersion.next())
        do {
            _ = try await clock.resolve(future, recursive: true) { _ in throw CocoaError(.fileReadUnknown) }
            throw CocoaError(.fileWriteUnknown)
        } catch let error as NSError {
            try require(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue)
        }
        for invalid in [Data(), Data([1, 2, 3]), Data(repeating: 0, count: DomainVersionSnapshot.archiveLimit + 1)] {
            do {
                _ = try await clock.resolve(invalid, recursive: true) { _ in throw CocoaError(.fileReadUnknown) }
                throw CocoaError(.fileWriteUnknown)
            } catch let error as CocoaError where error.code == .fileReadCorruptFile {}
        }
        print("PASS nil requests carry no new-scope authority and future, malformed or oversized versions fail closed")

        let target = rows[64]
        let pending = Task {
            try await clock.resolve(target.archive, recursive: true) { _ in
                try await Task.sleep(for: .seconds(10))
                return target
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let monotonic = ContinuousClock()
        let cancelledAt = monotonic.now
        pending.cancel()
        do { _ = try await pending.value; throw CocoaError(.fileWriteUnknown) }
        catch is CancellationError {}
        try require(cancelledAt.duration(to: monotonic.now) < .seconds(1))
        print("PASS request-context cancellation interrupts pending history lookup without advancing domain state")

        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<128 {
                        let value = clock.domainVersion
                        if value != clock.domainVersion { return false }
                    }
                    return true
                }
            }
            for try await value in group { try require(value) }
        }
        print("PASS synchronous domain getters safely serve concurrent framework callbacks from an immutable locked snapshot")
        return 6
    }
}
