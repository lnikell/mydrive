# NAS transport

Rust SMB transport used by MyDrive's macOS File Provider adapter. Swift owns
Apple integration and the callback lifecycle; the Catalog owns durable intent
and completion records. This helper owns one signed SMB session and bounded
remote work. It does not run a background synchronization or mutation scheduler.

`smb2` is pinned to **0.31.0** and `Cargo.lock` pins its dependencies. Build and
run local tests with a project-local dependency cache:

```sh
CARGO_HOME="$PWD/.cargo-home" cargo build --release --locked
CARGO_HOME="$PWD/.cargo-home" cargo test --release --locked
CARGO_HOME="$PWD/.cargo-home" cargo clippy --release --locked --all-targets -- -D warnings
./target/release/nas-transport --help
```

The initial dependency fetch needs network access. Local tests use canned SMB
frames and temporary files; the NAS contract test is ignored by default.

## Native request protocol

The app invokes `nas-transport --request-stdin` with no other arguments. Stdin
contains one versioned JSON request and ends at EOF. The envelope requires
`version: 1`, `host`, `share`, `username`, `password` and `operation`. The helper
refuses interactive stdin, unknown fields and requests over **65,536 bytes**.
Passwords arrive privately at runtime, limited to 4096 UTF-8 bytes, and never in
argv. Rust zeroizes its request/password input buffers; the upstream SMB client
retains its own password copy until session teardown.

Keep remote names in JSON. macOS process-argument conversion can normalize
Unicode; the native input preserves NFC/NFD path bytes and option-like names.
Remote paths are share-relative, at most 4096 UTF-8 bytes and 128 components.
Traversal, alternate-stream syntax, control characters, ambiguous separators
and names ending in a space or dot are refused. Empty list/stat paths denote
the share root.

| `operation.type` | Operation fields | Result |
| --- | --- | --- |
| `probe` | None | Authenticated share connection and negotiated security. |
| `list` | `path`; optional `delete_scope` | Bounded pages, then exhaustive completion with the actual held directory's `entry`. |
| `stat` | `path`; optional `delete_scope` | `entry`, or explicit `null` for a missing path. Permission/metadata failures are errors. |
| `read` | `path`, new local `destination` | Full guarded hydration, confirmed `bytes` and same-handle `entry`. An owned partial local output is removed on failure. |
| `mutate` | Typed `request` | One durable mutation phase and its receipts. |
| `reconcile` | The same frozen `request` | Read-only inspection of an interrupted phase; no blind mutation replay. |

JSON Lines output starts with `connected`, including negotiated security.
Listings emit `page` events with at most 1000 entries each. Transfers emit real,
monotonic `progress.bytes`: the first positive sample immediately, then changed
samples at most every 100 ms. `complete.result` contains the final result.
Top-level `error` events include stable `code` and sanitized `message`; accept
future codes and do not parse text. Mutation outcomes, including uncertainty,
arrive in `complete.result` so callers can persist their recovery evidence.

An `entry` contains `name`, `bytes`, `directory`, `index_number`,
`created_filetime`, `modified_filetime`, `changed_filetime` and `attributes`.
FILETIME values are 100 ns ticks since 1601: decode identity/timestamps as
unsigned 64-bit integers, not floating point. Listings are observations, not an
atomic NAS snapshot. Index numbers are qualified with creation time and kind,
not used as global provider IDs. Root stat returns a real SMB observation,
not the Catalog's synthetic root.

## Durable mutation contract

Persist the complete intent before the first RPC, and every returned receipt
before continuing. A request requires a canonical lowercase nonzero UUID
`operation_id`, `kind`, share-relative `path`, and observed
`parent: {index_number, created_filetime}`. Existing items require a full
`expected` entry. `move` additionally requires `destination` and
`destination_parent`. File uploads require `payload` with an absolute private
local `source`, exact `bytes` and lowercase SHA-256. Optional `receipt` holds
`staged`/`archived` artifacts. See the [request models](src/mutation_request.rs)
and [stdin decoder](src/request.rs).

| Mutation kind | Behavior |
| --- | --- |
| `create_file` | Exclusively allocate a sidecar, upload/verify it, then publish without replacement. |
| `create_directory` | Exclusively prepare an empty directory sidecar, then publish without replacement. |
| `replace_file` | Verify the frozen base, prepare content/security, reserve and archive the base, then publish without replacement. |
| `move` | Verify source and both immediate parents; rename without replacement. Case/Unicode-only aliases require the same object and verified final stored spelling. |
| `delete` | Archive a guarded file for explicit cleanup, or remove an empty directory. Never recursively remove unknown descendants. |
| `cleanup` | Remove an exact operation artifact using its recorded identity/version and original parent guard. |

File upload has three caller-visible phases:

1. `not_applied` / `allocated`: a zero-byte ordinary sidecar has a creator-confirmed
   identity, creation time and security fingerprint. **No payload bytes precede
   this receipt.** Persist it before calling `mutate` again.
2. `not_applied` / `prepared`: the frozen payload was written, flushed, closed,
   reopened and fully hashed. Persist this receipt before publication. Directory
   creates begin at this phase.
3. `committed`: final identity, metadata and any payload digest were verified.
   Commit the Catalog/journal result before artifact cleanup.

Artifacts contain `path`, full `entry`, `cleanup_safe`, `phase`
(`allocated`/`prepared`) and optional `security_sha256`. An allocated file receipt
requires zero bytes, cleanup authority and a security fingerprint. For older
receipts, omitted phase means prepared; omitted cleanup authority means false.
An interrupted upload can reset/rewrite only its exact allocation-owned sidecar,
after identity, size, plain-file and security checks. This handles pipelined
holes without granting truncate authority over documents or archived originals.
A full remote hash after CLOSE remains mandatory.

`outcome` is `committed`, `not_applied`, `conflict` or `uncertain`; `code` explains
the phase/refusal. Reconcile a lost reply using the frozen intent and durable
receipts. An unreceipted sidecar is `allocation_unknown`: matching its name or
bytes never proves ownership. Preserve that path; any bounded fresh-UUID retry
policy belongs to the durable caller. Archives without sufficient cleanup proof
remain `cleanup_safe: false` and must be retained, never automatically destroyed.

Replacement archives the guarded base then publishes without replacement.
There is a namespace gap: this is **not atomic replacement or a server-side
version CAS**. A concurrent destination creator wins and is not overwritten.
Backups stay until the caller's durable commit and explicit safe cleanup. File
delete's namespace commit likewise does not prove permanent byte deletion until
its archived artifact has been cleaned.

## Recursive-delete fences

The app freezes a Catalog inventory and drives child operations in postorder.
The helper accepts optional `delete_scope` on list/stat and delete/cleanup:

```text
{ root_path, root: { index_number, created_filetime },
             parent: { index_number, created_filetime } }
```

The root-parent path is derived from `root_path`. Paths must be byte-exact roots
or descendants; case folding/Unicode normalization cannot expand membership.
The selected root and parent are compared under held ordinary-directory handles
that deny SMB write/delete access. Immediate parent guards remain required.
Changed selection objects refuse with `scope_changed`, retaining receipts.

For exact selected-root deletion, its extra root reservation is omitted so it
cannot forbid the helper's own deletion; the full guarded target and frozen
parent still apply. Scoped stat of that root can prove absence under its unchanged
parent, or must verify the present root identity. Descendant reads require both
selection objects. After child removals change directory timestamps, the caller
may persist a fresh empty-directory observation under its frozen identity/scope;
files retain frozen versions. The helper itself only deletes empty directories.

## Security, bounds and file features

- Named, signed sessions are mandatory; guest/unsigned sessions are refused.
  Server-required encryption is honored. Legacy `--require-encryption` also
  requires encryption on the selected share. Compression, DFS and automatic
  session reconnect are disabled.
- Hydration reserves against SMB writers/deleters, checks streams, and compares
  size, identity, creation/modify/change times and attributes before/after reads.
  Ordinary ancestor reservations prevent SMB path substitution. The app must
  also compare its requested File Provider content version.
- These are SMB sharing/change checks, not NAS snapshots. Server-local processes
  or other protocols may bypass sharing; timestamp precision can hide changes.
  There is no unrestricted multi-protocol concurrency guarantee.
- Hydration buffers eight logical 256 KiB ranges; wire reads are at most 64 KiB.
  Mutation writes/hashes use eight 64 KiB ranges: pending plus out-of-order
  completed payloads are bounded to 512 KiB, plus a local input buffer. Frames,
  hashing, encryption and runtime copies add memory; these are not RSS ceilings.
  All integrity passes remain, including complete remote hashes.
- Listing uses a held directory handle and 64 KiB queries. Missing child index
  numbers require bounded metadata-handle enrichment and observation checks;
  unsupported observations never gain invented identities.
- Cancellation/drop invalidates the session and retires owned in-flight work.
  Explicit handle cleanup has a three-second deadline; reconnect with a new
  session. Only macOS initial dial failures whose nonempty attempts are uniformly
  `HostUnreachable` receive a cancellable five-second retry-eligibility window.
  This does not identify an OS cause or cap an in-flight connect; authentication
  and file mutations are never automatically replayed.
- Hydration refuses named streams/resource forks and reparse points. It reads
  logical bytes without reproducing NAS EAs, ACLs, hardlink relations or sparse
  layout. File mutations require one link, zero EAs and only the unnamed stream.
  Nonempty local resource forks are refused. Sparse/compressed/encrypted
  replacement attributes are unsupported.
- Replacement preserves remote owner/group/DACL through security-descriptor
  create and exact readback, plus supported DOS attributes and creation time.
  Failure stops before payload upload/base archival. Privileged SACL/audit/label
  preservation is unqualified; local ACL/xattrs are not uploaded. New items
  inherit remote access security. Directory moves retain their object rather
  than copying a tree. Packages are directory trees here; application-specific
  package behavior requires separate qualification.

## Disposable commands and NAS checks

The older argv commands remain for dedicated-share exercises: `shares`, `probe`,
`list`, `read`, `prepare`, `cleanup`, `write`, `mkdir`, `rename` and `delete`.
They accept `--host HOST:445 --share SHARE --username USER --password-stdin`;
`shares` omits `--share`. Stdin is a private password stream ending at EOF.
`list --pages N` can return a partial listing; `read` accepts `--offset`/`--length`
and refuses an existing local destination.

Exercise mutations require `--test-root .mydrive-transport-tests/<run-name>` and
relative children. `prepare` creates that namespace; `cleanup` removes only its
verified empty run directory, never its parent. Legacy mutations do not carry
the native durable receipt/parent contract; legacy `rename --replace` explicitly
permits overwrite. Use native requests for app writes. Native requests themselves
are share-relative and not automatically confined to the exercise prefix; test
harnesses enforce that extra containment. Server ACLs constrain the NAS account.

Run live checks only with explicit authorization for a dedicated account/share
and fresh generated root. Repository tools `tools/run_nas_check.py` and
`tools/nas_mutation_check.py` prompt privately; nonsecret metadata comes from
ignored local configuration or the public example, never a password file.
The mutation harness verifies hashes, exact membership and owned cleanup;
ambiguity retains evidence. Live reports and endpoint details stay private.

The ignored Rust contract also accepts `NAS_TEST_ENABLE=1`, `NAS_TEST_HOST`,
`NAS_TEST_SHARE`, `NAS_TEST_USER` and a fresh
`NAS_TEST_ROOT=.mydrive-transport-tests/<unique-run>`, with password on stdin:

```sh
CARGO_HOME="$PWD/.cargo-home" cargo test --release --locked --test nas_contract \
  -- --ignored --test-threads=1
```

That contract covers signed login, exclusive legacy upload, range/full integrity,
sharing exclusion, listing, rename and deletion. Canned wire tests separately
cover mutation phases, receipts, conflicts, partial writes, out-of-order replies,
cancellation and Scope2. Passing checks do not establish universal NAS
compatibility or a performance ranking.

## Dependency provenance

`smb2` is licensed MIT OR Apache-2.0:

- [Pinned source](https://github.com/vdavid/smb2/tree/v0.31.0)
- [Release changelog](https://github.com/vdavid/smb2/blob/v0.31.0/CHANGELOG.md)
