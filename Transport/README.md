# NAS transport experiment

An isolated Rust candidate for the native Mac app's transport. It is not yet the
File Provider adapter or sync engine. `smb2` is pinned to **0.31.0**; Cargo.lock
pins transitive dependencies. Real NAS checks are opt-in and use a dedicated
test share and reserved experiment directory.

Build and test using a project-local dependency cache:

```sh
CARGO_HOME="$PWD/.cargo-home" cargo build --release --locked
CARGO_HOME="$PWD/.cargo-home" cargo test --locked
./target/release/nas-transport --help
```

The first fetch needs network access. No global tools or packages are installed.

## Interface

The `Nas` module owns the session, signing checks, paging, transfer buffers,
temporary-file lifecycle and cancellation. The CLI emits one JSON object per
line. A `connected` event reports negotiated security. `page` events arrive as
server replies are received, split into at most 1000 entries per JSON event;
`--pages` limits server batches. `complete.result.complete` distinguishes a completed
listing from a deliberate page limit. Timestamps are raw SMB FILETIME ticks
(100 ns since 1601); remote index numbers are hints, not global item identities.
Decode these integers as `UInt64`, not floating point: FILETIME exceeds the
exact-integer range of a `Double`. Read completions return
`{"bytes":N,"entry":{...}}`, with the same metadata keys as a listing entry.
Errors include a stable `code` plus a sanitized human-readable `message`;
callers should accept unknown future codes and avoid parsing the message.

Supply `--host HOST:445 --share SHARE --username USER --password-stdin` and a
command. Passwords arrive from a trusted process through stdin, terminated by
EOF. The CLI refuses interactive stdin and never accepts a password option or
logs credentials. Do not put a literal secret in a shell command. The input
copy is zeroized; the upstream client holds its own copy until session teardown.

Commands:

| Command | Behavior |
| --- | --- |
| `shares` | Signed, read-only RPC discovery of disk shares; `--share` is omitted for this command. Enumeration does not prove access rights. |
| `probe` | Authenticate, connect the explicit share and report security. |
| `list [REMOTE] [--pages N]` | Stream directory pages; omit REMOTE for share root. |
| `read REMOTE NEW_LOCAL_FILE [--offset N] [--length N]` | Guarded download of all or a range; refuse an existing local file. Remove an owned partial local output on error. Return observed metadata with the byte count. |
| `prepare` | Create the reserved experiment namespace and selected run directory. |
| `cleanup` | Remove exactly the configured empty experiment run directory. Reject files/reparse points; never recurse or remove the reserved parent. |
| `write LOCAL_FILE REMOTE_RELATIVE` | Exclusive temporary sibling, bounded upload, FLUSH/CLOSE, rename without replacement. |
| `mkdir REMOTE_RELATIVE` | Create one directory. |
| `rename FROM_RELATIVE TO_RELATIVE [--replace]` | Rename; replacement requires the explicit flag. |
| `delete REMOTE_RELATIVE [--directory]` | Delete one file or empty directory; never recursive. |

All mutation commands require
`--test-root .mydrive-transport-tests/<run-name>`. Mutation paths are relative to
that directory; reads/listings are relative to the selected share. Absolute
paths, traversal, alternate-stream syntax and ambiguous separators are refused.
Run `prepare` before the other mutation commands.

Use a **dedicated NAS account and test share**. The path guard is lexical;
server ACLs provide containment. It does not defeat a concurrent server-side
symlink/reparse-point change. Never use this experiment on valuable documents.

## Security, bounds and cancellation

- A named, signed session is mandatory. Guest/unsigned sessions are refused.
- Server-required encryption is honored. `--require-encryption` also refuses
  an unencrypted selected share; it does not reconfigure the NAS.
- Compression and DFS are disabled to make the initial comparison explicit.
- Reads use eight positioned requests of at most 256 KiB, about 2 MiB of
  buffered range payload; each range uses wire reads of at most 64 KiB so a
  single-credit server can make progress. Writes use a 256 KiB producer buffer and a 4 MiB
  connection write budget. These are payload limits, **not** a process RSS cap;
  protocol parsing, encryption and runtime allocations add overhead.
- Ctrl-C stops transfer scheduling. Cancellation invalidates the session;
  construct a new `Nas` afterward. Handles are closed explicitly, with a fixed
  cleanup deadline; timed-out cleanup invalidates the connection.
- Automatic reconnect/replay is off. An uncertain mutation is reported as an
  error. No comparison-and-swap or multiwriter safety is claimed.
- Hydration opens a read handle with `FILE_SHARE_READ` only: conflicting SMB
  writers/deleters must be refused by the server. The handle stays open while
  basic, standard and index metadata are queried before and after bounded
  reads. Observed size, creation/modify/change times, attributes and index must
  agree. Failure to obtain the reservation or metadata fails the download.
  This is an SMB sharing reservation with change detection, **not a NAS
  snapshot**: a server process or another protocol may bypass SMB sharing and
  timestamp resolution can hide changes. The app must also compare returned
  metadata against its requested File Provider content version.
- A network failure may leave an identifiable `.upload-*.partial` sibling.
  The prototype never deletes a final path to recover an uncertain rename.
- Sparse-file layout, resource forks, xattrs, symlinks and permissions are not
  round-tripped by this byte-transfer experiment.

## Opt-in NAS contract test

The ignored test mutates only an explicitly supplied experiment root. Set
`NAS_TEST_ENABLE=1`, `NAS_TEST_HOST`, `NAS_TEST_SHARE`, `NAS_TEST_USER`, and a fresh
`NAS_TEST_ROOT=.mydrive-transport-tests/<unique-run>`. Pipe the password on stdin
and run only this test:

```sh
CARGO_HOME="$PWD/.cargo-home" cargo test --locked --test nas_contract \
  -- --ignored --test-threads=1
```

It verifies signed login, exclusive upload, destination preservation, positioned
range reads, complete paged enumeration, rename and deletion. It also holds an
SMB writer open to ensure guarded hydration is refused, and attempts a second
overwrite while hydration holds its reservation to ensure the original bytes
survive. Credentials are
not read from repository files or password environment variables. The local
fixture directory is `.work/`, which is ignored. A failed run may retain remote
fixtures for inspection. The test must be explicitly authorized for the chosen
share before running.

## Dependency provenance

`smb2` is MIT OR Apache-2.0. The pinned series includes incremental directory
reading and fixes stale handles after reconnect and short WRITE handling.
This remains a young transport candidate, pending actual UNAS experiments:

- [Pinned source and license](https://github.com/vdavid/smb2/tree/v0.31.0)
- [Release changelog](https://github.com/vdavid/smb2/blob/v0.31.0/CHANGELOG.md)

No performance ranking is implied by a successful build or contract test.
