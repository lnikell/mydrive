import Foundation
@testable import MyDriveCore

/// The real SQLite boundary receives qualified remote outcomes. This peer
/// owns independent namespace observations; it performs no filesystem/NAS I/O.
final class ImportTrial {
    let fixture: Fixture
    let intent: JournalIntent
    let entries: [TreeImportEntry]
    let scope: TreeImportScope
    private var objects: [String: (parent: String, entry: RemoteEntry)] = [:]
    private var sequence: UInt64 = 1_000
    var catalog: Catalog { fixture.catalog }

    init(entries: [TreeImportEntry], name: String = "Document.rtfd", parent: RemoteEntry? = nil) async throws {
        fixture = try Fixture(); self.entries = entries
        let parentID: String
        if let parent {
            let scan = try await fixture.catalog.beginScan()
            try await fixture.catalog.stage([parent], in: scan)
            try await fixture.catalog.completeScan(scan)
            guard let id = try await fixture.catalog.child(named: parent.name, in: Catalog.rootID)?.id else {
                throw CatalogError.invalidEntry
            }
            parentID = id
        } else { parentID = Catalog.rootID }
        scope = .init(parentPath: parent?.name ?? "", parentIdentity: parent?.objectIdentity ?? .init(indexNumber: 10, createdFiletime: 11),
                      arenaName: ".mydrive-arena-" + UUID().uuidString.lowercased())
        var digest = TreeImportDigest()
        for entry in entries { try digest.append(entry) }
        let tree = try digest.reference(id: UUID())
        let template = UUID().uuidString
        let id = try await fixture.catalog.providerID(forCreateTemplate: template)
        intent = .init(itemID: id, expectedVersion: nil,
            action: .create(parentID: parentID, name: name, kind: .directory),
            createTemplateID: template, destinationPath: Catalog.treeJoin(scope.parentPath, name), tree: tree)
    }

    @discardableResult func prepare(in catalog: Catalog? = nil) async throws -> TreeImportStatus {
        try await (catalog ?? self.catalog).prepareTreeImport(intent: intent, scope: scope)
    }

    @discardableResult func freeze(in catalog: Catalog? = nil) async throws -> TreeImportStatus {
        let catalog = catalog ?? self.catalog
        let key = try await prepare(in: catalog).key
        for start in stride(from: 0, to: entries.count, by: 128) {
            _ = try await catalog.stageTreeImport(key: key, entries: Array(entries[start..<min(start + 128, entries.count)]))
        }
        let directories = entries.filter { $0.kind == .directory }.map(\.path).reversed()
        let seals = Array(directories)
        for start in stride(from: 0, to: seals.count, by: 128) {
            _ = try await catalog.stageTreeImport(key: key, entries: [],
                sealedDirectories: Array(seals[start..<min(start + 128, seals.count)]))
        }
        return try await catalog.stageTreeImport(key: key, entries: [], isComplete: true)
    }

    @discardableResult func apply(_ work: TreeImportWork, in catalog: Catalog? = nil) async throws -> TreeImportStatus {
        let catalog = catalog ?? self.catalog, key = intent.idempotencyKey
        switch work {
        case .mutation(let step, let intent, _, _):
            let operation = try await catalog.enqueueTreeImportChild(key: key, step: step, intent: intent)
            if operation.state == .queued {
                try await catalog.transitionOperation(key: operation.intent.idempotencyKey, from: .queued, to: .executing)
            }
            let entry = try outcome(step: step, intent: operation.intent)
            if case .create(let parent, _, _) = intent.action { objects[intent.itemID] = (parent, entry) }
            if case .move(let parent, _) = intent.action { objects[intent.itemID] = (parent, entry) }
            return try await catalog.recordTreeImportProgress(key: key,
                update: .committed(step: step, key: operation.intent.idempotencyKey, entry: entry,
                                   sha256: step == .create ? intent.payload?.sha256 : nil))
        case .verifyFile(let item, _, let payload):
            guard let entry = objects[item.id]?.entry else { throw CatalogError.invalidEntry }
            return try await catalog.recordTreeImportProgress(key: key,
                update: .fileVerified(itemID: item.id, entry: entry, sha256: payload.sha256))
        case .verifyDirectory(let item, _, let scan):
            let children = children(of: item.id)
            for start in stride(from: 0, to: children.count, by: 128) {
                _ = try await catalog.recordTreeImportProgress(key: key,
                    update: .directoryPage(itemID: item.id, scanID: scan,
                        entries: Array(children[start..<min(start + 128, children.count)])))
            }
            let entry = try directoryTerminal(item.id)
            return try await catalog.recordTreeImportProgress(key: key,
                update: .directoryComplete(itemID: item.id, scanID: scan, entry: entry))
        }
    }

    func placeAll(in catalog: Catalog? = nil) async throws -> [TreeImportWork] {
        let catalog = catalog ?? self.catalog
        for _ in 0..<(entries.count * 3 + 10) {
            let work = try await catalog.nextTreeImportWork(key: intent.idempotencyKey, limit: 128)
            if work.contains(where: { if case .mutation = $0 { return false }; return true }) { return work }
            for item in work { _ = try await apply(item, in: catalog) }
        }
        throw CatalogError.invalidTransition
    }

    func finish(in catalog: Catalog? = nil) async throws -> TreeImportStatus {
        let catalog = catalog ?? self.catalog
        for _ in 0..<(entries.count * 5 + 10) {
            let status = try await catalog.treeImportStatus(rootID: intent.itemID)
            if let status, status.phase == .published { return status }
            let work = try await catalog.nextTreeImportWork(key: intent.idempotencyKey, limit: 128)
            guard !work.isEmpty, work.count <= 128 else { throw CatalogError.invalidTransition }
            for item in work { _ = try await apply(item, in: catalog) }
        }
        throw CatalogError.invalidTransition
    }

    func readyToPublish() async throws -> TreeImportWork {
        for _ in 0..<(entries.count * 5 + 10) {
            let work = try await catalog.nextTreeImportWork(key: intent.idempotencyKey, limit: 128)
            if let publish = work.first, case .mutation(.publish, _, _, _) = publish { return publish }
            guard !work.isEmpty else { throw CatalogError.invalidTransition }
            for item in work { _ = try await apply(item) }
        }
        throw CatalogError.invalidTransition
    }

    func children(of id: String) -> [RemoteEntry] {
        objects.values.filter { $0.parent == id }.map(\.entry)
            .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    func directoryTerminal(_ id: String) throws -> RemoteEntry {
        guard let object = objects[id], object.entry.kind == .directory else { throw CatalogError.invalidEntry }
        let old = object.entry
        let entry = RemoteEntry(name: old.name, kind: .directory,
            contentVersion: old.contentVersion + ":listed", metadataVersion: old.metadataVersion + ":listed",
            objectIdentity: old.objectIdentity)
        objects[id] = (object.parent, entry)
        return entry
    }

    func outcome(step: TreeImportStep, intent: JournalIntent) throws -> RemoteEntry {
        let name: String, kind: ItemKind, identity: RemoteObjectIdentity, size: Int64
        switch intent.action {
        case .create(_, let filename, let type):
            sequence += 1; name = filename; kind = type; size = intent.payload?.size ?? 0
            identity = .init(indexNumber: sequence, createdFiletime: sequence + 1)
        case .move(_, let filename):
            guard let base = intent.baseEntry, let id = base.objectIdentity else { throw CatalogError.invalidEntry }
            name = filename; kind = base.kind; size = base.size; identity = id
        default: throw CatalogError.invalidEntry
        }
        return .init(name: name, kind: kind, contentVersion: "v:\(identity.indexNumber):\(step.rawValue)",
                     metadataVersion: "m:\(identity.indexNumber):\(step.rawValue)", size: size, objectIdentity: identity)
    }
}

func importFile(_ path: String, size: Int64 = 42, hash: String = String(repeating: "a", count: 64)) -> TreeImportEntry {
    .init(path: path, kind: .file, payload: .init(id: UUID(), size: size, sha256: hash))
}

func importTreeReference(_ entries: [TreeImportEntry]) throws -> StagedTreeReference {
    var digest = TreeImportDigest()
    for entry in entries { try digest.append(entry) }
    return try digest.reference(id: UUID())
}

func insertTreeTestOperation(_ intent: JournalIntent, in db: SQLiteConnection) throws {
    let data = try JSONEncoder().encode(intent)
    try db.execute("INSERT INTO operations(idempotency_key,item_id,intent,state,request_fingerprint) VALUES(?,?,?,'queued',?)",
        [.text(intent.idempotencyKey.uuidString), .text(intent.itemID), .text(String(decoding: data, as: UTF8.self)),
         .text(intent.requestFingerprint)])
}
