import Testing
@testable import MyDriveCore

@Suite struct ObservedDirectoryTests {
    @Test func refreshCandidatesExcludeRootFilesUnopenedAndRetiredDirectories() async throws {
        let fixture = try Fixture()
        let entries = [directory("observed"), directory("unopened"),
                       directory("removed"), directory("becomes-file"), file("plain-file")]
        try await publish(entries, to: fixture.catalog)
        let children = try await fixture.catalog.children().items
        for name in ["observed", "removed", "becomes-file"] {
            let id = try #require(children.first { $0.entry.name == name }?.id)
            try await publish([], to: fixture.catalog, parentID: id)
        }
        let unopened = try #require(children.first { $0.entry.name == "unopened" }?.id)
        let interrupted = try await fixture.catalog.beginScan(of: unopened)
        try await fixture.catalog.stage([file("unpublished")], in: interrupted)
        #expect(try await fixture.catalog.observedDirectories().map(\.entry.name).sorted()
            == ["becomes-file", "observed", "removed"])

        // Stable identity can leave an observed row behind after a kind change.
        try await publish([directory("observed"), directory("unopened"),
                           file("becomes-file"), file("plain-file")], to: fixture.catalog)
        let candidates = try await fixture.catalog.observedDirectories()
        #expect(candidates.map(\.entry.name) == ["observed"])
        #expect(candidates.allSatisfy { $0.id != Catalog.rootID && !$0.isDeleted && $0.entry.kind == .directory })
        #expect(try await fixture.catalog.hasCompletedScan(of: Catalog.rootID))
        try await fixture.catalog.abandonScan(interrupted)
    }

    @Test func boundedKeysetSurvivesRestartAndUnrelatedPublication() async throws {
        let fixture = try Fixture()
        let directories = (0..<5).map { directory("folder-\($0)") }
        let files = (0..<256).map { file("file-\($0)") }
        try await publish(directories + files, to: fixture.catalog)
        let children = try await fixture.catalog.children(limit: 1_000).items
        for item in children where item.entry.kind == .directory {
            try await publish([], to: fixture.catalog, parentID: item.id)
        }
        let expected = children.filter { $0.entry.kind == .directory }.map(\.id).sorted()
        let first = try await fixture.catalog.observedDirectories(limit: 2)
        #expect(first.map(\.id) == Array(expected.prefix(2)))
        let bookmark = try #require(first.last?.id)
        let reopened = try Catalog(databaseURL: fixture.url)
        // A refresh is a live pass: another scan's generation advance must not
        // force an unrelated directory bookmark to restart from the beginning.
        try await publish(directories + files + [file("new-file")], to: reopened)
        let middle = try await reopened.observedDirectories(afterID: bookmark, limit: 2)
        #expect(middle.map(\.id) == Array(expected[2..<4]))
        let last = try await reopened.observedDirectories(afterID: try #require(middle.last?.id), limit: 2)
        #expect(last.map(\.id) == Array(expected.suffix(1)))
        #expect(try await reopened.observedDirectories(afterID: try #require(last.last?.id), limit: 2).isEmpty)
        #expect(first.count <= 2 && middle.count <= 2 && last.count <= 2)
        #expect(Set((first + middle + last).map(\.id)).count == expected.count)
    }

    @Test func directoryPageLimitsAreValidated() async throws {
        let fixture = try Fixture()
        #expect(try await fixture.catalog.observedDirectories(limit: 1).isEmpty)
        for limit in [0, -1, 1_001] {
            await #expect(throws: CatalogError.invalidPageSize) {
                try await fixture.catalog.observedDirectories(limit: limit)
            }
        }
    }

    private func directory(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, kind: .directory, remoteKey: name, contentVersion: "v1", metadataVersion: "v1")
    }

    private func file(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, kind: .file, remoteKey: name, contentVersion: "v1", metadataVersion: "v1", size: 42)
    }

    private func publish(_ entries: [RemoteEntry], to catalog: Catalog, parentID: String = Catalog.rootID) async throws {
        let scan = try await catalog.beginScan(of: parentID)
        try await catalog.stage(entries, in: scan)
        try await catalog.completeScan(scan)
    }
}
