import FileProvider
import Foundation
import MyDriveCore
import Darwin

extension MutationTests {
    static func staleContentConflict() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let conflictPeer = MutationPeer()
        let conflict = try fixture(root.appendingPathComponent("conflict"), conflictPeer)
        let base = await conflictPeer.seed(path: "Shared.txt", bytes: Data("base".utf8))
        let scan = try await conflict.catalog.beginScan()
        try await conflict.catalog.stage([base.observation], in: scan)
        try await conflict.catalog.completeScan(scan)
        let original = try await conflict.catalog.children().items[0]
        let remoteEdit = await conflictPeer.seed(path: "Shared.txt", bytes: Data("remote edit".utf8))
        let editInput = try MutationInput(item: WriteTemplate(id: original.id, name: "Shared.txt"), fields: [.contents], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(base.observation.contentVersion.utf8),
                                                  metadataVersion: Data(base.observation.metadataVersion.utf8)))
        let resolved = try await conflict.write(editInput, create: false, progress: Progress(totalUnitCount: 1))
        let siblings = try await conflict.catalog.children().items
        try mutationCheck(resolved.id == original.id && resolved.entry.name.contains("(conflict ") && siblings.count == 2,
                          "Content conflict changed local identity or lost a sibling")
        let originalAfterConflict = await conflictPeer.stat("Shared.txt")
        try mutationCheck(siblings.contains(where: { $0.id != original.id && $0.entry == remoteEdit.observation }) &&
                          originalAfterConflict == remoteEdit,
                          "Content conflict overwrote or mislabeled the original remote version")
        try mutationCheck(await conflictPeer.hash(resolved.entry.name) == MutationPeer.hash(bytes), "Conflict sibling did not preserve local bytes")
        let conflictReplay = try await conflict.write(editInput, create: false, progress: Progress(totalUnitCount: 1))
        try mutationCheck(conflictReplay.id == resolved.id && conflictReplay.entry == resolved.entry,
                          "Conflict callback replay did not return the original receipt")
        print("PASS stale-base content edits preserve both versions and the original local Finder identity")
        return 1
    }

    static func atomicSaveConflict() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let atomicPeer = MutationPeer()
        let atomic = try fixture(root.appendingPathComponent("atomic-save"), atomicPeer)
        let atomicBase = await atomicPeer.seed(path: "Atomic.txt", bytes: Data("base".utf8))
        let atomicScan = try await atomic.catalog.beginScan()
        try await atomic.catalog.stage([atomicBase.observation], in: atomicScan)
        try await atomic.catalog.completeScan(atomicScan)
        let originalAtomicID = try await atomic.catalog.children().items[0].id
        let remoteAtomicBytes = Data("NAS editor replaced this file atomically".utf8)
        let atomicReplacement = await atomicPeer.seed(path: "Atomic.txt", bytes: remoteAtomicBytes)
        let replacementScan = try await atomic.catalog.beginScan()
        try await atomic.catalog.stage([atomicReplacement.observation], in: replacementScan)
        try await atomic.catalog.completeScan(replacementScan)
        try mutationCheck(try await atomic.catalog.children().items[0].id == originalAtomicID,
                          "A same-path atomic file save retired the still-dirty local Finder identity")
        let atomicInput = try MutationInput(item: WriteTemplate(id: originalAtomicID, name: "Atomic.txt"), fields: [.contents], contents: source,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(atomicBase.observation.contentVersion.utf8),
                                                  metadataVersion: Data(atomicBase.observation.metadataVersion.utf8)))
        let atomicSaved = try await atomic.write(atomicInput, create: false, progress: Progress(totalUnitCount: 1))
        let atomicOriginalHash = await atomicPeer.hash("Atomic.txt")
        let atomicLocalHash = await atomicPeer.hash(atomicSaved.entry.name)
        try mutationCheck(atomicSaved.id == originalAtomicID && atomicSaved.entry.name.contains("(conflict ") &&
            atomicOriginalHash == MutationPeer.hash(remoteAtomicBytes) && atomicLocalHash == MutationPeer.hash(bytes),
            "A refresh before the old-base callback prevented preserving both local and remote file bytes")
        print("PASS an observed atomic NAS file replacement retains the dirty Finder ID and old-base upload preserves both byte versions")
        return 1
    }

    static func unicodeRename() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local bytes — café\n".utf8)
        let source = root.appendingPathComponent("system-owned.txt")
        try bytes.write(to: source)

        let unicodeRoot = root.appendingPathComponent("unicode")
        let unicodeCatalog = try Catalog(databaseURL: unicodeRoot.appendingPathComponent("catalog.sqlite"))
        let nfc = "caf\u{e9}.txt"
        let nfd = "cafe\u{301}.txt"
        let unicodeBase = SMBEntry(name: nfc, bytes: 0, directory: false, index_number: 123,
                                   created_filetime: 100, modified_filetime: 200, changed_filetime: 300, attributes: 0x20)
        let unicodeScan = try await unicodeCatalog.beginScan()
        try await unicodeCatalog.stage([unicodeBase.observation], in: unicodeScan)
        try await unicodeCatalog.completeScan(unicodeScan)
        let unicodeItem = try await unicodeCatalog.children().items[0]
        let unicodeAdapter = ProviderMutations(catalog: unicodeCatalog,
            staging: try MutationStaging(root: unicodeRoot.appendingPathComponent("Mutations")),
            remote: MutationRemote(stat: { path in path.isEmpty ? MutationPeer.rootEntry : path.utf8.elementsEqual(nfc.utf8) ? unicodeBase : nil },
                mutate: { request, reconcile, _ in
                    guard request.kind == .move, !reconcile,
                          request.path.utf8.elementsEqual(nfc.utf8),
                          request.destination?.utf8.elementsEqual(nfd.utf8) == true else {
                        throw MutationTestFailure(message: "Normalization-only rename changed its wire paths")
                    }
                    let renamed = SMBEntry(name: nfd, bytes: 0, directory: false, index_number: 123,
                        created_filetime: 100, modified_filetime: 200, changed_filetime: 301, attributes: 0x20)
                    return SMBMutationResult(operation_id: request.operation_id, outcome: .committed, code: "committed",
                        entry: renamed, sha256: nil, cleanup_pending: false, receipt: .init())
                }), checkActive: { try Task.checkCancellation() })
        let unicodeInput = try MutationInput(item: WriteTemplate(id: unicodeItem.id, name: nfd), fields: [.filename], contents: nil,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(unicodeBase.observation.contentVersion.utf8),
                                                  metadataVersion: Data(unicodeBase.observation.metadataVersion.utf8)))
        let unicodeRenamed = try await unicodeAdapter.write(unicodeInput, create: false, progress: Progress(totalUnitCount: 1))
        try mutationCheck(unicodeRenamed.id == unicodeItem.id && unicodeRenamed.entry.name.utf8.elementsEqual(nfd.utf8),
                          "NFC/NFD rename was mistaken for a no-op or normalized in Catalog")
        print("PASS normalization-only rename preserves exact source/destination UTF-8 and Finder identity")
        return 1
    }

    static func caseAliasRename() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let caseRoot = root.appendingPathComponent("case-alias")
        let caseCatalog = try Catalog(databaseURL: caseRoot.appendingPathComponent("catalog.sqlite"))
        let caseBase = SMBEntry(name: "Foo.txt", bytes: 0, directory: false, index_number: 321,
                                created_filetime: 100, modified_filetime: 200, changed_filetime: 300, attributes: 0x20)
        let caseRenamed = SMBEntry(name: "foo.txt", bytes: 0, directory: false, index_number: 321,
                                   created_filetime: 100, modified_filetime: 200, changed_filetime: 301, attributes: 0x20)
        let caseScan = try await caseCatalog.beginScan()
        try await caseCatalog.stage([caseBase.observation], in: caseScan)
        try await caseCatalog.completeScan(caseScan)
        let caseItem = try await caseCatalog.children().items[0]
        let caseStaging = try MutationStaging(root: caseRoot.appendingPathComponent("Mutations"))
        let caseAdapter = ProviderMutations(catalog: caseCatalog, staging: caseStaging,
            remote: MutationRemote(stat: { path in
                path.isEmpty ? MutationPeer.rootEntry : ["Foo.txt", "foo.txt"].contains(path) ? caseBase : nil
            }, mutate: { request, reconcile, _ in
                guard request.kind == .move, !reconcile, request.path == "Foo.txt", request.destination == "foo.txt" else {
                    throw MutationTestFailure(message: "Case-alias rename did not reach guarded backend move")
                }
                return SMBMutationResult(operation_id: request.operation_id, outcome: .committed, code: "committed",
                    entry: caseRenamed, sha256: nil, cleanup_pending: false, receipt: .init())
            }), checkActive: { try Task.checkCancellation() })
        let caseInput = try MutationInput(item: WriteTemplate(id: caseItem.id, name: "foo.txt"), fields: [.filename], contents: nil,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(caseBase.observation.contentVersion.utf8),
                                                  metadataVersion: Data(caseBase.observation.metadataVersion.utf8)))
        let caseResult = try await caseAdapter.write(caseInput, create: false, progress: Progress(totalUnitCount: 1))
        try mutationCheck(caseResult.id == caseItem.id && caseResult.entry.name.utf8.elementsEqual("foo.txt".utf8),
                          "Case-only rename was rejected before the identity-aware backend")
        let other = SMBEntry(name: "FOO.txt", bytes: 0, directory: false, index_number: 999,
                             created_filetime: 999, modified_filetime: 200, changed_filetime: 300, attributes: 0x20)
        let refusingPlan = MutationPreparation(catalog: caseCatalog, staging: caseStaging,
            remote: MutationRemote(stat: { path in path.isEmpty ? MutationPeer.rootEntry : path == "foo.txt" ? caseRenamed : other },
                mutate: { _, _, _ in throw MutationTestFailure(message: "Planner performed a mutation") }))
        let collidingCase = try MutationInput(item: WriteTemplate(id: caseItem.id, name: "FOO.txt"), fields: [.filename], contents: nil,
            baseVersion: NSFileProviderItemVersion(contentVersion: Data(caseRenamed.observation.contentVersion.utf8),
                                                  metadataVersion: Data(caseRenamed.observation.metadataVersion.utf8)))
        do {
            _ = try await refusingPlan.prepare(collidingCase, create: false, key: UUID(), payload: nil)
            throw MutationTestFailure(message: "Different target identity was accepted as a case alias")
        } catch let error as NSError {
            try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.filenameCollision.rawValue,
                              "Different target identity did not preserve native collision handling")
        }
        print("PASS planner admits same-object case aliases but rejects a different destination identity before mutation")
        return 1
    }

    static func conflictFilenameBound() async throws -> Int {

        let longName = "x." + String(repeating: "e", count: 250)
        let boundedName = ProviderMutations.conflictName(longName, key: UUID())
        try mutationCheck(boundedName.utf8.count <= 255 && boundedName.contains("(conflict "), "A long extension produced an invalid conflict filename")
        print("PASS conflict filename byte bounds include unusually long extensions")
        return 1
    }

}
