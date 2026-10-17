# Local catalog

`MyDriveCore` is a native Swift package using the system SQLite library through a small C module map. No external package resolution, NAS credentials, network access, payload storage, or background scheduler is involved. One `Catalog` actor belongs to the domain coordinator for a configured share.

```swift
import MyDriveCore

let catalog = try Catalog(databaseURL: localApplicationSupportURL)
let scan = try await catalog.beginScan(of: Catalog.rootID)
try await catalog.stage(remoteEntries, in: scan) // up to 1,000 observations per call
try await catalog.completeScan(scan)           // only after exhaustive success
let page = try await catalog.children(limit: 128)
```

The database must be on a local volume outside the provider's content folder. Initialization verifies WAL and `synchronous=FULL`, enables macOS full-fsync, disables SQLite memory mapping, and sets a 2 MiB page-cache target. The target is not a total process-memory ceiling.

An interrupted or abandoned scan cannot alter the published listing. Completing a scan publishes its observations and missing-item tombstones in one transaction. A transport-supplied `remoteKey` that is share-wide unique per directory entry and stable across rename/reconnect preserves item identity across renames and moves. When no stable key is available, only an existing entry at the same parent/name retains its identity. Do not supply session handles, arbitrary hashes, or unreliable server identifiers as stable keys. An object identifier shared by multiple hard links does not satisfy this contract.

Listings use keyset cursors with a catalog generation. Each page holds at most `limit + 1` entries, with a maximum requested limit of 1,000. Cursors are Codable so the Apple adapter can encode a continuation token. A publication that changes the catalog invalidates older cursors; identical refreshes preserve them. Restart enumeration on `staleCursor`. `knownItems(afterID:limit:)` provides bounded ID-ordered working-set pages; its caller checks `generation()` between pages. `hasCompletedScan(of:)` distinguishes an observed empty folder from an undiscovered folder. `relativePath(id:)` resolves an item through live ancestors. A complete scan runs as one database transaction and should stay off the main actor. Initial discovery currently publishes on completion; progressive indexing and a durable File Provider change feed are follow-up work.

Offline selections are durable and inherited from parent folders. Clearing them changes policy; it does not evict or delete any content. The Apple adapter must protect dirty and open files when requesting eviction.

The journal currently models rename, move, and delete intent for future write support. Enqueue uses an idempotency key and rejects reuse for different work. Its checked transitions never turn an uncertain operation directly into an executing operation. The coordinator must reconcile the NAS outcome before recording `queued`, `completed`, or `failed`.

Call `recoverInterruptedOperations()` only after obtaining exclusive domain ownership. Opening a database does not recover executing operations automatically, because another process may still own them. This package supplies no owner election or lease.

The tests cover SQLite configuration, interrupted scans and rollback, complete-scan publication, rename identity and pin persistence, inherited pins, bounded enumeration and stale cursors, journal replay and idempotency, and persisted connection state. Run `swift test` with full Xcode. A CLT-only host may need its bundled Swift Testing framework added to the compiler and linker framework search paths, and `--disable-xctest`.
