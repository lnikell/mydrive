import Foundation

extension Catalog {
    static let hasAssignedScanItemsSQL = "SELECT EXISTS(SELECT 1 FROM scan_entries WHERE scan_id = ? AND item_id IS NOT NULL)"
    /// Published positives are usable even when their earlier scan failed.
    /// This does not assert completeness or infer any remote absence.
    public func hasPublishedChildren(of parentID: String = Catalog.rootID) throws -> Bool {
        try requireDirectory(parentID)
        return try database.scalarInt("SELECT EXISTS(SELECT 1 FROM items WHERE parent_id = ? AND is_deleted = 0)",
                                      [.text(parentID)]) != 0
    }

    /// Ordinary refresh only. Stages one bounded batch and may publish ONE new
    /// prefix before EOF. Recursive inventory continues to use atomic stage.
    /// `directory` must be the initial observation from the held listing handle.
    public func stageVisibleAdditions(_ entries: [RemoteEntry], in scan: CatalogScan,
                                      directory: RemoteEntry) throws -> Bool {
        try Self.validateScanEntries(entries)
        return try database.transaction {
            try requireScan(scan)
            try requireDirectory(scan.parentID)
            try qualifyVisibleDirectory(directory, for: scan)
            // The implicit rowid bounds selection to this submitted batch,
            // without revisiting a growing failed/deferred scan prefix.
            let boundary = try database.scalarInt("SELECT COALESCE(max(rowid),0) FROM scan_entries")
            try stageScanEntries(entries, in: scan)
            guard try !hasCompletedScan(of: scan.parentID),
                  try !hasPublishedChildren(of: scan.parentID),
                  try !hasUnfinishedMutations(),
                  try database.scalarInt(Self.hasAssignedScanItemsSQL,
                                         [.text(scan.id)]) == 0 else { return false }
            try resolveScannedIdentities(scan, visibleAfter: boundary)
            guard try database.scalarInt(Self.hasAssignedScanItemsSQL,
                                         [.text(scan.id)]) != 0 else { return false }
            try publishScannedRows(scan, visibleAfter: boundary)
            try database.execute("INSERT OR IGNORE INTO observed_directories(item_id,is_complete) VALUES (?,0)", [.text(scan.parentID)])
            try database.execute("UPDATE catalog_state SET generation = generation + 1 WHERE singleton = 1")
            return true
        }
    }

    private func qualifyVisibleDirectory(_ directory: RemoteEntry, for scan: CatalogScan) throws {
        if scan.parentID != Self.rootID {
            _ = try qualifyScannedDirectory(directory, for: scan)
            return
        }
        // The configured share/held-handle binding belongs to the adapter.
        // Root stays synthetic: validate the observation, never install its ID.
        guard directory.kind == .directory, directory.size >= 0, directory.remoteKey != "",
              directory.modifiedAt?.timeIntervalSince1970.isFinite != false,
              let identity = directory.objectIdentity, identity.indexNumber > 0, identity.createdFiletime > 0,
              scan.path == "", let frozen = scan.directory, frozen.id == Self.rootID,
              let live = try item(id: Self.rootID), !live.isDeleted, live.entry.kind == .directory,
              frozen == live, try relativePath(id: Self.rootID) == "" else { throw CatalogError.invalidParent }
    }
}
