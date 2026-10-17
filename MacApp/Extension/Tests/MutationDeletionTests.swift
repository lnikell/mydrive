import FileProvider
import Foundation
import MyDriveCore
import Darwin

extension MutationTests {
    static func nonemptyRefusal() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let protectedPeer = MutationPeer()
        let protected = try fixture(root.appendingPathComponent("delete"), protectedPeer)
        let directory = await protectedPeer.seed(path: "Folder", bytes: Data(), directory: true)
        _ = await protectedPeer.seed(path: "Folder/child.txt", bytes: Data("child".utf8))
        let directoryScan = try await protected.catalog.beginScan()
        try await protected.catalog.stage([directory.observation], in: directoryScan)
        try await protected.catalog.completeScan(directoryScan)
        let directoryItem = try await protected.catalog.children().items[0]
        do {
            try await protected.delete(id: directoryItem.id, contentVersion: Data(directory.observation.contentVersion.utf8),
                                       metadataVersion: Data(directory.observation.metadataVersion.utf8), progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Nonempty directory deletion was acknowledged")
        } catch let error as NSFileProviderError {
            try mutationCheck(error.code == .directoryNotEmpty, "Directory refusal lost its native recovery error")
        }
        let retainedDirectory = try await protected.catalog.item(id: directoryItem.id)
        let retainedChild = await protectedPeer.stat("Folder/child.txt")
        try mutationCheck(retainedDirectory?.isDeleted == false && retainedChild != nil,
                          "Refused directory deletion removed data or tombstoned Catalog")
        print("PASS nonempty directory delete is rejected without recursive remote data loss")
        return 1
    }

    static func renameReplay() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let movePeer = MutationPeer()
        let moveRecovery = try fixture(root.appendingPathComponent("move-recovery"), movePeer)
        let moveBase = await movePeer.seed(path: "Before.txt", bytes: Data("move bytes".utf8))
        let moveScan = try await moveRecovery.catalog.beginScan()
        try await moveRecovery.catalog.stage([moveBase.observation], in: moveScan)
        try await moveRecovery.catalog.completeScan(moveScan)
        let moveItem = try await moveRecovery.catalog.children().items[0]
        let moveInput = try MutationInput(item: WriteTemplate(id: moveItem.id, name: "After.txt"), fields: [.filename], contents: nil,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(moveBase.observation.contentVersion.utf8),
                                                  metadataVersion: Data(moveBase.observation.metadataVersion.utf8)))
        await movePeer.loseReply()
        do {
            _ = try await moveRecovery.write(moveInput, create: false, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Lost move reply was acknowledged")
        } catch SMBClientError.serverUnreachable {}
        let remoteAfterMove = await movePeer.stat("After.txt")!
        let refreshBetweenReplies = try await moveRecovery.catalog.beginScan()
        try await moveRecovery.catalog.stage([remoteAfterMove.observation], in: refreshBetweenReplies)
        try await moveRecovery.catalog.completeScan(refreshBetweenReplies)
        let observedAlias = try await moveRecovery.catalog.children().items[0]
        try mutationCheck(observedAlias.id != moveItem.id, "Recovery fixture did not create a scan alias")
        let recoveredMove = try await moveRecovery.write(moveInput, create: false, progress: Progress(totalUnitCount: 1))
        let recoveredItems = try await moveRecovery.catalog.children().items
        let retiredAlias = try await moveRecovery.catalog.item(id: observedAlias.id)
        try mutationCheck(recoveredMove.id == moveItem.id && recoveredItems.count == 1 && retiredAlias?.isDeleted == true,
                          "Journal replay consulted a tombstoned live item or failed to atomically retire its exact alias")
        try mutationCheck((await movePeer.counts()).1 == 1, "Recovered move was applied twice")
        print("PASS journal-first replay survives an intervening scan and atomically retires the verified destination alias")
        return 1
    }

    static func compoundRenameAndMetadataRetry() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let compoundPeer = MutationPeer()
        let compound = try fixture(root.appendingPathComponent("compound"), compoundPeer)
        let old = await compoundPeer.seed(path: "Old.txt", bytes: Data("old".utf8))
        let oldScan = try await compound.catalog.beginScan()
        try await compound.catalog.stage([old.observation], in: oldScan)
        try await compound.catalog.completeScan(oldScan)
        let oldItem = try await compound.catalog.children().items[0]
        await compoundPeer.removeOldPathAfterPublish("Old.txt")
        let compoundInput = try MutationInput(item: WriteTemplate(id: oldItem.id, name: "Renamed.txt"),
            fields: [.contents, .filename], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(old.observation.contentVersion.utf8),
                                                  metadataVersion: Data(old.observation.metadataVersion.utf8)))
        let moved = try await compound.write(compoundInput, create: false, progress: Progress(totalUnitCount: 1))
        let compoundItems = try await compound.catalog.children().items
        try mutationCheck(moved.id == oldItem.id && moved.entry.name == "Renamed.txt" && compoundItems.count == 1,
                          "Verified content+rename stalled after external removal of its old path")
        try mutationCheck(await compoundPeer.hash("Renamed.txt") == MutationPeer.hash(bytes), "Compound edit lost local bytes")
        print("PASS content+rename completes after definite old-path disappearance without inventing a conflict sibling")
        let noOpCalls = await compoundPeer.counts()
        let noOp = try MutationInput(item: WriteTemplate(id: moved.id, name: moved.entry.name),
            fields: [.contentModificationDate], contents: nil,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(moved.entry.contentVersion.utf8),
                                                  metadataVersion: Data(moved.entry.metadataVersion.utf8)))
        _ = try await compound.write(noOp, create: false, progress: Progress(totalUnitCount: 1))
        let noOpAfter = await compoundPeer.counts()
        try mutationCheck(noOp.pendingFields == [.contentModificationDate] && noOpCalls.2 == noOpAfter.2,
                          "Unsupported metadata-only retry became a permanent error or was falsely consumed")
        print("PASS metadata-only retries preserve pending fields and make no remote mutation")
        return 2
    }

    static func permanentCleanup() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let deletePeer = MutationPeer()
        let deleting = try fixture(root.appendingPathComponent("permanent-delete"), deletePeer)
        let deleteBase = await deletePeer.seed(path: "Delete.txt", bytes: Data("delete".utf8))
        let deleteScan = try await deleting.catalog.beginScan()
        try await deleting.catalog.stage([deleteBase.observation], in: deleteScan)
        try await deleting.catalog.completeScan(deleteScan)
        let deleteItem = try await deleting.catalog.children().items[0]
        await deletePeer.failNextCleanup()
        do {
            try await deleting.delete(id: deleteItem.id, contentVersion: Data(deleteBase.observation.contentVersion.utf8),
                metadataVersion: Data(deleteBase.observation.metadataVersion.utf8), progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Permanent delete was acknowledged while its NAS bytes remained")
        } catch let error as CocoaError {
            try mutationCheck(error.code == .fileWriteUnknown, "Pending delete cleanup lost its retryable native error")
        }
        let deleteCalls = await deletePeer.counts()
        try await deleting.delete(id: deleteItem.id, contentVersion: Data(deleteBase.observation.contentVersion.utf8),
            metadataVersion: Data(deleteBase.observation.metadataVersion.utf8), progress: Progress(totalUnitCount: 1))
        let deleteAfter = await deletePeer.counts()
        try mutationCheck(deleting.staging.planKeys(limit: 10).isEmpty && deleteCalls.1 == deleteAfter.1,
                          "Permanent-delete replay did another namespace mutation or retained confirmed cleanup")
        print("PASS permanent deletion waits for NAS byte cleanup and replay resumes cleanup only")
        return 1
    }

}
