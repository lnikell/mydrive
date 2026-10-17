# Releasing MyDrive

The same scripts prepare a local release and a GitHub Actions release for [lnikell/mydrive](https://github.com/lnikell/mydrive). Apple distribution signing and CI secrets still require setup. `python3 tools/release.py doctor` lists what is missing. No published app update or successful signed upgrade is claimed until those steps run against real credentials.

## One-time setup

1. Verify this checkout's `origin` and the public repository in `release/config.json`. The source uses MIT, as selected by the owner. Run `python3 tools/check-publication.py --working-tree` before staging; private research, plans, local agent instructions, build output, signing material and local NAS metadata are excluded. Set `git config core.hooksPath .githooks` in a new clone to enable the commit guard.
2. Finalize the app/provider bundle identifiers and App Group before the first public release. Register matching Apple identifiers, enable the required capabilities, create Developer ID provisioning profiles for both bundles, and install a **Developer ID Application** identity with its private key. Set the public `team_id`, `app_group_id` and provisioned `keychain_access_group`. Preserve these identifiers for every subsequent update.
3. Fetch the pinned Sparkle tools with `python3 tools/fetch-sparkle.py`. Run `.build/dependencies/Sparkle-2.10.0/bin/generate_keys --account mydrive-release` once. It creates or reuses a Keychain private key and prints the public key. Copy only that public key to `sparkle_public_key` in release configuration. Back up the private key securely; losing it complicates future updates.
4. Configure notarization using a `notarytool` Keychain profile, or an App Store Connect API key with the necessary role. Enter account credentials directly into Apple's tools; never send them through chat or commit them.
5. Commit configuration, release notes, source and workflows. Protect release tags and restrict who can change the Release workflow. GitHub's optional immutable releases fit the draft-first upload procedure.

Local release environment (paths and public identity names, not raw secrets):

| Variable | Purpose |
| --- | --- |
| `MYDRIVE_SIGN_IDENTITY` | Developer ID Application certificate name or SHA-1 identity |
| `MYDRIVE_HOST_PROFILE` | Matching app `.provisionprofile` path |
| `MYDRIVE_PROVIDER_PROFILE` | Matching extension `.provisionprofile` path |
| `MYDRIVE_NOTARY_KEYCHAIN_PROFILE` | Stored `notarytool` profile |
| `MYDRIVE_SPARKLE_KEY_FILE` | Optional mode-0600 exported key; otherwise uses Keychain account `mydrive-release` |

Instead of the notarization Keychain profile, set `MYDRIVE_NOTARY_KEY_PATH`, `MYDRIVE_NOTARY_KEY_ID` and `MYDRIVE_NOTARY_ISSUER_ID`. Never pass a private key's contents as a command-line argument. Install and authenticate GitHub CLI (`gh`) for local uploads. The current release channel is arm64/macOS 15+, and the appcast declares its hardware requirement.

## Future fixes and versions

After implementing and checking a fix:

```sh
python3 tools/release.py bump 0.2.1 --build 3
# Write release/notes/0.2.1.md, commit the intended changes, then:
git tag v0.2.1
git push origin main
git push origin v0.2.1
```

The tag starts `.github/workflows/release.yml`. The workflow accepts manual reruns on that same tag. It runs tests without NAS access, imports credentials into a temporary CI Keychain, builds in an isolated release workspace, notarizes, staples, archives with preserved framework links, generates a signed feed, and verifies the extracted archive. It saves those exact prepared bytes as a CI artifact for 30 days before uploading the complete set into a draft. Publication is the final step. It restores the runner's Keychain search list and removes temporary signing material afterward. A retry recovers and verifies the same commit's artifact from the Release workflow; if a partial draft exists and its original artifact is unavailable, it stops before rebuilding.

For local execution from the clean release tag:

```sh
python3 tools/release.py doctor
python3 tools/release.py prepare
python3 tools/release.py verify
python3 tools/release.py publish
```

Artifacts appear in `dist/releases/vX.Y.Z/` only after preparation succeeds. The archive URL contains the immutable version tag. The app reads `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml`; all assets become public together. A partial upload can resume with `publish` using the same prepared artifacts. Existing mismatched or public assets stop the command. Rebuilding a signed/notarized archive produces different bytes: do not mix a rebuilt archive with a partially uploaded draft; inspect the retained draft and original artifacts before taking any recovery action.

## GitHub release environment

Create an environment named `release`. The workflow has no mandatory reviewer gate, so authorized future releases can run autonomously. Add these secrets directly in GitHub's settings:

| Secret | Contents |
| --- | --- |
| `MYDRIVE_CERTIFICATE_P12_BASE64` | Base64 export containing the Developer ID certificate and private key |
| `MYDRIVE_CERTIFICATE_PASSWORD` | That export's password |
| `MYDRIVE_HOST_PROFILE_BASE64` | Base64 app provisioning profile |
| `MYDRIVE_PROVIDER_PROFILE_BASE64` | Base64 provider provisioning profile |
| `MYDRIVE_SPARKLE_PRIVATE_KEY` | Exported Sparkle private key text, not an extra base64 encoding |
| `MYDRIVE_NOTARY_KEY_BASE64` | Base64 `.p8` API key |

Add environment variables `MYDRIVE_SIGN_IDENTITY`, `MYDRIVE_NOTARY_KEY_ID`, and `MYDRIVE_NOTARY_ISSUER_ID`. `GH_TOKEN` comes from the workflow's short-lived GitHub token, scoped to repository contents. No NAS password is needed. Secret import refuses to run outside a GitHub-hosted runner and refuses a workflow repository/tag that differs from the configured version.

The first real signed release needs an installed old-to-new update trial: confirm stable Finder locations, saved credentials, offline files, download indicators, offload and removal. The local test suite verifies release guards and signature handling; it cannot prove Apple's signing, notarization service or a real Sparkle installation without the account setup.

Primary references: [Sparkle integration](https://sparkle-project.org/documentation/), [sandbox integration and nested signing](https://sparkle-project.org/documentation/sandboxing/), [signed update publication](https://sparkle-project.org/documentation/publishing/), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [GitHub draft releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).
