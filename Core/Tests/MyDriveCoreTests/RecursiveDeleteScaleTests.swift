import Testing
@testable import MyDriveCore

@Suite struct RecursiveDeleteScaleTests {
    @Test func tenThousandFilesUseBoundedPostorderBatchesAndKeepTheRootPending() async throws {
        let f = try Fixture()
        let rootEntry = RemoteEntry(name: "tree", kind: .directory, contentVersion: "directory", metadataVersion: "metadata",
                                    objectIdentity: .init(indexNumber: 1, createdFiletime: 2))
        let parent = try await f.catalog.beginScan()
        try await f.catalog.stage([rootEntry], in: parent)
        try await f.catalog.completeScan(parent)
        let root = try #require(try await f.catalog.child(named: "tree", in: Catalog.rootID))
        let status = try await f.catalog.prepareRecursiveDelete(intent: recursiveIntent(root),
            rootParentIdentity: .init(indexNumber: 50_000, createdFiletime: 50_001))
        let scan = try await f.catalog.beginScan(of: root.id)
        for page in 0..<10 {
            let entries = (0..<1_000).map { offset in
                let index = UInt64(page * 1_000 + offset + 2)
                return RemoteEntry(name: "file-\(index)", kind: .file, contentVersion: "v\(index)", metadataVersion: "m\(index)", size: 42,
                                   objectIdentity: .init(indexNumber: index, createdFiletime: index + 1))
            }
            try await f.catalog.stage(entries, in: scan)
        }
        let captured = try await f.catalog.captureDeleteDirectory(key: status.key, scan: scan, directory: rootEntry)
        #expect(captured.totalNodes == 10_001)
        var removed = 0
        while removed < 10_000 {
            let work = try await f.catalog.nextRecursiveDeleteWork(key: status.key, limit: 137)
            #expect(!work.isEmpty && work.count <= 137)
            var updates: [RecursiveDeleteProgress] = []
            for value in work {
                let (id, childKey) = try await childOperation(value, in: f.catalog)
                #expect(id != root.id)
                updates.append(.bindOperation(itemID: id, key: childKey))
                updates.append(.removed(itemID: id, key: childKey))
            }
            let progress = try await f.catalog.recordRecursiveDeleteProgress(key: status.key, updates: updates)
            removed += work.count
            #expect(progress.removedNodes == Int64(removed))
        }
        let reopened = try Catalog(databaseURL: f.url)
        let last = try await reopened.nextRecursiveDeleteWork(key: status.key, limit: 1)
        #expect(last.count == 1)
        if case .remove(let item, _, _, _, _) = try #require(last.first) { #expect(item.id == root.id) }
        #expect(try await reopened.operation(key: status.key)?.state != .completed)
        #expect(try await reopened.item(id: root.id)?.isDeleted == false)
    }
}
