# MyDrive

Native macOS NAS client in development, using Swift and File Provider for Finder integration, SQLite for durable local state, and a bounded Rust SMB transport.

## Current implementation

- A compact native drive list with Add/Reconnect sheets and per-drive Finder, refresh, offload and removal actions.
- An Uninstall MyDrive action that disconnects all drives, removes clean downloads and identifies preserved local work before showing the app in Finder.
- Multiple saved SMB Connections, each with its own stable Finder Domain, Catalog, credentials and refresh monitor.
- Sparkle 2.10 native update checks and automatic download/install preferences, with local scripts publishing signed and notarized updates to GitHub Releases. Public distribution still needs Apple signing configuration.
- A replicated File Provider adapter for real NAS listings and on-demand downloads.
- Journaled ordinary-file uploads, edits, renames and moves, with conflict copies and resumable transfer receipts. Interrupted uploads have recovered across connection loss and provider restart in native Finder tests.
- A durable, bounded folder-import inventory with at most four concurrent child transfers, destination-depth staging and identity-checked publication. The transport has live dedicated-share qualification; the complete native directory-payload path still needs qualification.
- Finite, durable folder-deletion inventories with identity checks that preserve moved or replaced objects.
- Finder Keep Downloaded and Free Up Space actions, verified with real files and an unopened nested folder on the UNAS.
- Native Finder cloud and download-progress indicators, driven by macOS materialization state and real transferred bytes. Progress remains below completion until content validation succeeds.
- Automatic checks of previously scanned folders while MyDrive runs, with backoff for connection failures and a pause when credentials need attention.
- A local SQLite Catalog with interrupted-scan, identity, paging, policy, and journal tests.
- Signed SMB sessions with dedicated-share integrity, conflict, recovery and namespace tests.

This is a development preview. Fresh first-drive Finder activation has passed native tests. Package-document creation, editing, rename and deletion are currently refused to preserve the originals and local edits; package support remains under qualification. Signed installation, unattended credentials and an actual installed Sparkle update also need qualification. Resource forks/named streams, symlinks, Finder aliases and metadata editing are not supported; unsupported content is refused rather than silently flattened. Source POSIX modes, ACLs and extended attributes are not round-tripped; new objects inherit destination NAS permissions. Sparse allocation, compression and hardlink relationships are not preserved. Ordinary-byte tests do not establish compatibility with every NAS or macOS file type.

## Build and test

```sh
bash tools/check.sh
bash tools/build-macos.sh
open dist/MyDrive.app
```

The current CLT-only build produces an explicitly labeled ad-hoc development bundle. Finder listing, text/Unicode hydration, recursive offline policy, selected/global offload, and provider restart recovery have passed on this Mac. A normal signed build needs an appropriate developer identity, profiles/App Group, and shared Keychain authorization. The build script never invents a developer team or disables macOS protections.

The ad-hoc diagnostic stores connection metadata in ignored `.runtime/`. Its restricted test service lets each provider Domain create and read back its own encrypted Keychain record. This survives a restart of the unchanged provider, is scoped to one build, Domain and the exact dedicated test endpoint, and expires after fifteen minutes. Expiry prevents reuse; physical Keychain deletion is lazy or explicit. Remove development Connections before rebuilding to clean that build's records. This is development qualification, not unattended production credential storage. The production path requires Apple-issued signing and a provisioned shared Keychain group. Passwords never belong in source, arguments, `.env`, diagnostic reports or the Catalog.

The native adapter sends typed, bounded JSON through stdin. This preserves exact NAS Unicode names; macOS normalized some names when they were passed through Swift Process arguments.

For the authorized NAS experiment, these commands prompt privately for the dedicated account password:

```sh
python3 tools/run_nas_check.py probe
python3 tools/run_nas_check.py contract
python3 tools/nas_benchmark.py --confirm-test-share
```

Copy `config/nas-test.example.json` to ignored `.local/nas-test.json` and set your dedicated test server, share and account before running live tests or building a development app for that server. This file contains endpoint metadata only; passwords are entered privately and never saved there. Experiments confine mutations to a fresh `.mydrive-transport-tests/<run>` directory on that explicit test share.

## Storage cleanup

Free Up Space evicted both 2 MiB files in a nested folder after one Finder action; global offload also passed. NAS hashes remained unchanged. Pending edits and open files may be retained. Remove Connection uses an explicit File Provider removal mode and reports preserved local work; actual removal deleted the managed folder and hydrated payloads with no cleanup failures.

**Moving the app to Trash alone does not guarantee removal of its downloaded files.** The real test retained a hydrated 2 MiB file and Finder offered a separate Delete MyDrive data action. Use **Uninstall MyDrive… → Disconnect All & Remove Downloads** before deleting the app. Preparation removes each registered drive through File Provider, checks for remaining drives and offers **Quit and Show App in Finder** when cleanup succeeds. Pending edits and upload-recovery data are preserved and shown; incomplete removal prevents a successful preparation result. Native tests removed two drives' hydrated files, verified that drive-wide offload freed disk space independently, and exercised the corrected quit/reveal/Trash sequence. Finder layout metadata can be retained in a small export. Per-drive Disconnect & Remove Local Downloads remains available. macOS provides no guaranteed app-to-Trash uninstall callback.

## Releases

Releases run entirely on your Mac. `python3 tools/release.py doctor` reports missing setup, and `python3 tools/release.py ship` checks, builds, signs, notarizes and publishes the tagged version. The [release guide](docs/releasing.md) covers the local settings and exact source/tag steps. GitHub hosts source and update assets; no GitHub Actions workflows are used. Version/build numbers and public settings live in `release/`. Development builds never start public update checks.

`python3 tools/check-publication.py --working-tree` previews files eligible for Git. The checked-in pre-commit hook and release checks reject private documents, credential files and recognizable secret formats, including files force-added past `.gitignore`. Enable the hook in a new clone with `git config core.hooksPath .githooks`. Research, plans, local agent instructions, runtime reports and test-server metadata stay local. The Sparkle public verification key is intentionally public; its private signing key stays in Keychain or a private local file.

MyDrive source is available under the [MIT license](LICENSE). Dependencies retain their own licenses. Both app bundles include complete dependency license texts in `Contents/Resources/ThirdPartyLicenses.txt`; local release verification checks that they match the packaged version.
