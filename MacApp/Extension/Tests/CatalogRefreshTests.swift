import FileProvider
import Foundation
import MyDriveCore

private actor ResolvedErrors {
    var codes: [NSFileProviderError.Code] = []
    func append(_ code: NSFileProviderError.Code) { codes.append(code) }
}

private actor RefreshDelivery {
    private var resolutionFailure = true
    private var notificationFailure = false
    private(set) var notifications = 0

    func resolve() throws {
        if resolutionFailure {
            resolutionFailure = false
            throw CocoaError(.fileReadUnknown)
        }
    }

    func failNextNotification() { notificationFailure = true }

    func notify() throws {
        if notificationFailure {
            notificationFailure = false
            throw CocoaError(.fileReadUnknown)
        }
        notifications += 1
    }
}

enum CatalogRefreshTests {
    static func run() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try Catalog(databaseURL: root.appendingPathComponent("catalog.sqlite"))
        let listingIdentity = RemoteObjectIdentity(indexNumber: 1, createdFiletime: 1)
        let listingDirectory = RemoteEntry(name: "", kind: .directory, contentVersion: "held-root", metadataVersion: "held-root", objectIdentity: listingIdentity)
        let original = RemoteEntry(name: "Original.txt", kind: .file, contentVersion: "original", metadataVersion: "original")
        let candidate = RemoteEntry(name: "Incomplete.txt", kind: .file, contentVersion: "candidate", metadataVersion: "candidate")
        let scan = try await catalog.beginScan()
        try await catalog.stage([original], in: scan); try await catalog.completeScan(scan)
        try await catalog.setConnectionState(.offline)
        let resolved = ResolvedErrors()
        let publication = CatalogPublication()
        let incomplete = CatalogRefresh(catalog: catalog, publication: publication, list: { _, page in
            try await page([candidate])
            throw SMBClientError.serverUnreachable
        }, resolve: { await resolved.append($0) }, notify: {}, checkActive: { try Task.checkCancellation() })
        do { _ = try await incomplete.run(parentID: Catalog.rootID, path: ""); throw CocoaError(.fileReadUnknown) }
        catch SMBClientError.serverUnreachable {}
        let partialItems = try await catalog.children().items
        guard await resolved.codes.isEmpty, partialItems.count == 1,
              partialItems[0].entry == original, try await catalog.connectionState() == .offline else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("PASS partial failed listing preserves Catalog and cannot clear native authentication/network backoff")

        let complete = CatalogRefresh(catalog: catalog, publication: publication, list: { _, _ in listingDirectory }, resolve: { code in
            // Online is published only once the verified listing and native
            // recovery notifications have both completed successfully.
            guard try await catalog.connectionState() == .offline else { throw CocoaError(.fileReadCorruptFile) }
            await resolved.append(code)
        }, notify: {}, checkActive: { try Task.checkCancellation() })
        _ = try await complete.run(parentID: Catalog.rootID, path: "")
        guard await resolved.codes == [.notAuthenticated, .serverUnreachable],
              try await catalog.connectionState() == .online,
              try await catalog.children().items.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        print("PASS exhaustive empty listing proves recovery before clearing native backoff and publishing online")

        let online = CatalogRefresh(catalog: catalog, publication: publication, list: { _, _ in listingDirectory },
            resolve: { _ in throw CocoaError(.fileReadUnknown) }, notify: {}, checkActive: { try Task.checkCancellation() })
        _ = try await online.run(parentID: Catalog.rootID, path: "")
        _ = await CatalogRefresh.recordFailure(SMBClientError.authenticationRequired, in: catalog)
        guard try await catalog.connectionState() == .authenticationRequired else { throw CocoaError(.fileReadCorruptFile) }
        print("PASS online refresh avoids repeated recovery notifications and upload/fetch authentication failures remain recoverable")

        let delivery = RefreshDelivery()
        let retryPublication = CatalogPublication()
        let retry = CatalogRefresh(catalog: catalog, publication: retryPublication, list: { _, page in
            try await page([candidate])
            return listingDirectory
        }, resolve: { _ in try await delivery.resolve() }, notify: {
            guard try await catalog.connectionState() == .online else { throw CocoaError(.fileReadCorruptFile) }
            try await delivery.notify()
        }, checkActive: { try Task.checkCancellation() })
        do { _ = try await retry.run(parentID: Catalog.rootID, path: ""); throw CocoaError(.fileReadCorruptFile) }
        catch let error as CocoaError where error.code == .fileReadUnknown {}
        let committedGeneration = try await catalog.generation()
        guard try await catalog.children().items.first?.entry == candidate,
              try await catalog.connectionState() == .authenticationRequired,
              await delivery.notifications == 0 else { throw CocoaError(.fileReadCorruptFile) }
        _ = try await retry.run(parentID: Catalog.rootID, path: "")
        _ = try await retry.run(parentID: Catalog.rootID, path: "")
        guard try await catalog.generation() == committedGeneration,
              await delivery.notifications == 1 else { throw CocoaError(.fileReadCorruptFile) }
        print("PASS committed scan survives error-resolution failure and identical retry delivers its pending Finder notification once")

        // The coordinator records a verified mutation through this same owner
        // before attempting its best-effort notification. No scan delta is
        // necessary to recover a notification lost after that callback commit.
        await retryPublication.record(changed: true)
        await delivery.failNextNotification()
        do { try await retryPublication.notify { try await delivery.notify() }; throw CocoaError(.fileReadCorruptFile) }
        catch let error as CocoaError where error.code == .fileReadUnknown {}
        _ = try await retry.run(parentID: Catalog.rootID, path: "")
        _ = try await retry.run(parentID: Catalog.rootID, path: "")
        guard await delivery.notifications == 2 else { throw CocoaError(.fileReadCorruptFile) }
        print("PASS a verified mutation notification failure remains pending for an identical refresh without repeating the mutation")

        let restarted = CatalogRefresh(catalog: catalog, publication: CatalogPublication(), list: { _, page in
            try await page([candidate])
            return listingDirectory
        }, resolve: { _ in throw CocoaError(.fileReadCorruptFile) }, notify: {
            try await delivery.notify()
        }, checkActive: { try Task.checkCancellation() })
        await delivery.failNextNotification()
        do { _ = try await restarted.run(parentID: Catalog.rootID, path: ""); throw CocoaError(.fileReadCorruptFile) }
        catch let error as CocoaError where error.code == .fileReadUnknown {}
        _ = try await restarted.run(parentID: Catalog.rootID, path: "")
        _ = try await restarted.run(parentID: Catalog.rootID, path: "")
        guard await delivery.notifications == 3 else { throw CocoaError(.fileReadCorruptFile) }
        print("PASS replacement owner signals durable changes and a failed Finder notification remains retryable without duplicate delivery")

        let directoryCatalog = try Catalog(databaseURL: root.appendingPathComponent("directory.sqlite"))
        let expected = RemoteObjectIdentity(indexNumber: 20, createdFiletime: 30)
        let replacement = RemoteObjectIdentity(indexNumber: 21, createdFiletime: 31)
        let directory = RemoteEntry(name: "Directory", kind: .directory, contentVersion: "opaque", metadataVersion: "opaque", objectIdentity: expected)
        let legacy = RemoteEntry(name: "Legacy", kind: .directory, contentVersion: "opaque", metadataVersion: "opaque")
        let parentScan = try await directoryCatalog.beginScan()
        try await directoryCatalog.stage([directory, legacy], in: parentScan)
        try await directoryCatalog.completeScan(parentScan)
        let parents = try await directoryCatalog.children().items
        let directoryID = parents.first { $0.entry.name == "Directory" }!.id
        let legacyID = parents.first { $0.entry.name == "Legacy" }!.id
        let oldChildren = try await directoryCatalog.beginScan(of: directoryID)
        try await directoryCatalog.stage([original], in: oldChildren)
        try await directoryCatalog.completeScan(oldChildren)
        try await directoryCatalog.setConnectionState(.offline)
        let replacedDirectory = CatalogRefresh(catalog: directoryCatalog, publication: CatalogPublication(), list: { _, page in
            try await page([candidate])
            return RemoteEntry(name: "Directory", kind: .directory, contentVersion: "replacement", metadataVersion: "replacement", objectIdentity: replacement)
        }, resolve: { _ in throw CocoaError(.fileReadCorruptFile) }, notify: { throw CocoaError(.fileReadCorruptFile) },
            checkActive: { try Task.checkCancellation() })
        do {
            _ = try await replacedDirectory.run(parentID: directoryID, path: "Directory")
            throw CocoaError(.fileReadCorruptFile)
        } catch MutationParentError.replaced(let id) { guard id == directoryID else { throw CocoaError(.fileReadCorruptFile) } }
        guard try await directoryCatalog.children(of: directoryID).items.map(\.entry) == [original],
              try await directoryCatalog.connectionState() == .offline else { throw CocoaError(.fileReadCorruptFile) }
        print("PASS held-directory identity mismatch discards every staged page and preserves cached children and offline state")

        let missingIdentity = CatalogRefresh(catalog: directoryCatalog, publication: CatalogPublication(), list: { _, _ in
            throw CocoaError(.fileReadCorruptFile)
        }, resolve: { _ in throw CocoaError(.fileReadCorruptFile) }, notify: { throw CocoaError(.fileReadCorruptFile) },
            checkActive: { try Task.checkCancellation() })
        do {
            _ = try await missingIdentity.run(parentID: legacyID, path: "Legacy")
            throw CocoaError(.fileReadCorruptFile)
        } catch MutationParentError.refreshRequired(let id) { guard id == legacyID else { throw CocoaError(.fileReadCorruptFile) } }
        guard try await directoryCatalog.hasCompletedScan(of: legacyID) == false else { throw CocoaError(.fileReadCorruptFile) }
        print("PASS identity-free cached directories require their containing listing before any child scan can be published")
        try await heldDirectoryPublication(root: root)
        return 9
    }

    private static func heldDirectoryPublication(root: URL) async throws {
        let catalog = try Catalog(databaseURL: root.appendingPathComponent("held-directory.sqlite"))
        let identity = RemoteObjectIdentity(indexNumber: 31, createdFiletime: 41)
        let initial = RemoteEntry(name: "Folder", kind: .directory, contentVersion: "before", metadataVersion: "before", objectIdentity: identity)
        let parentScan = try await catalog.beginScan()
        try await catalog.stage([initial], in: parentScan)
        try await catalog.completeScan(parentScan)
        guard let folder = try await catalog.child(named: "Folder", in: Catalog.rootID) else { throw CocoaError(.fileReadCorruptFile) }
        let generation = try await catalog.generation()
        let anchor = try await catalog.currentChangeAnchor()
        let terminal = RemoteEntry(name: "Folder", kind: .directory, contentVersion: "after", metadataVersion: "after", objectIdentity: identity)
        let child = RemoteEntry(name: "Created.txt", kind: .file, contentVersion: "bytes", metadataVersion: "attributes", size: 7)
        let refresh = CatalogRefresh(catalog: catalog, publication: CatalogPublication(), list: { path, page in
            guard path == "Folder" else { throw CocoaError(.fileReadCorruptFile) }
            try await page([child])
            return terminal
        }, resolve: { _ in throw CocoaError(.fileReadCorruptFile) }, notify: {
            // Finder's wakeup must observe both the new child's metadata and
            // the selected folder's updated version from this same scan.
            guard try await catalog.item(id: folder.id)?.entry == terminal,
                  try await catalog.child(named: child.name, in: folder.id)?.entry == child else { throw CocoaError(.fileReadCorruptFile) }
        }, checkActive: { try Task.checkCancellation() })
        guard try await refresh.run(parentID: folder.id, path: "Folder"),
              try await catalog.generation() == generation + 1 else { throw CocoaError(.fileReadCorruptFile) }
        let changes = try await catalog.changes(since: anchor)
        guard changes.updated.count == 2, changes.updated.contains(where: { $0.id == folder.id }),
              try await refresh.run(parentID: folder.id, path: "Folder") == false,
              try await catalog.generation() == generation + 1 else { throw CocoaError(.fileReadCorruptFile) }
        print("PASS held terminal directory metadata and children publish atomically before Finder wakeup and identical refresh stays quiet")
    }
}
