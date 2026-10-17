# MyDrive

Native macOS NAS client in development. The approved design uses a Swift host and File Provider adapter, a durable local SQLite Catalog, and a bounded SMB transport. The current transport candidate is Rust `smb2`.

## Current implementation

- A compact native drive list with Add/Reconnect sheets and per-drive Finder, refresh, offload and removal actions.
- Multiple saved SMB Connections, each with its own stable Finder Domain, Catalog, credentials and refresh monitor.
- Sparkle 2.10 native update checks and automatic download/install preferences, with local scripts publishing signed and notarized updates to GitHub Releases. Public distribution still needs Apple signing configuration.
- A replicated File Provider adapter for real NAS listings and full-file hydration. Remote writes remain disabled until their journal and concurrency semantics are verified.
- Finder Keep Downloaded and Free Up Space actions, verified with real files and an unopened nested folder on the UNAS.
- Native Finder cloud and download-progress indicators, driven by macOS materialization state and real transferred bytes. Progress remains below completion until content validation succeeds.
- Automatic checks of previously scanned folders while MyDrive runs, with backoff for connection failures and a pause when credentials need attention.
- A local SQLite Catalog with interrupted-scan, identity, paging, policy, and journal tests.
- A signed SMB experiment with real dedicated-share integrity tests.

## Build and test

```sh
bash tools/test-core.sh
bash tools/test-mac-adapters.sh
bash tools/test-provider-adapters.sh
bash tools/test-updater.sh
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

**Moving the app to Trash does not currently free its downloaded files.** The real test retained a hydrated 2 MiB file and Finder offered a separate Delete MyDrive data action. Use Disconnect & Remove Local Downloads before deleting the app. Automatic Trash cleanup, remote editing/conflicts, unattended credentials, incremental change history and distribution signing remain unfinished; this is a read-only development alpha.

## Releases

Releases run entirely on your Mac. `python3 tools/release.py doctor` reports missing setup, and `python3 tools/release.py ship` checks, builds, signs, notarizes and publishes the tagged version. The [release guide](docs/releasing.md) covers the local settings and exact source/tag steps. GitHub hosts source and update assets; no GitHub Actions workflows are used. Version/build numbers and public settings live in `release/`. Development builds never start public update checks.

`python3 tools/check-publication.py --working-tree` previews files eligible for Git. The checked-in pre-commit hook and release checks reject private documents, credential files and recognizable secret formats, including files force-added past `.gitignore`. Enable the hook in a new clone with `git config core.hooksPath .githooks`. Research, plans, local agent instructions, runtime reports and test-server metadata stay local. The Sparkle public verification key is intentionally public; its private signing key stays in Keychain or a private local file.

MyDrive source is available under the [MIT license](LICENSE). Dependencies retain their own licenses.
