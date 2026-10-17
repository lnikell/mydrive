# Releasing MyDrive locally

All checks, builds, signing, notarization and publication run on the release Mac through `tools/release.py`. GitHub hosts [the source and release assets](https://github.com/lnikell/mydrive); there are no GitHub Actions workflows or hosted signing secrets. The tested tools are Swift 6.2.3/macOS SDK 26.2 and Rust 1.93.0. Command Line Tools or Xcode can supply the Apple tools. The release channel is arm64/macOS 15+.

## One-time setup

1. Verify `origin` and `release/config.json` point to the intended repository. Enable the local commit guard with `git config core.hooksPath .githooks`. The source uses MIT. Plans, research, agent instructions, local settings, build output and signing material stay ignored.
2. Register the app/provider bundle identifiers and App Group with Apple. Install a **Developer ID Application** identity with its private key and matching Developer ID provisioning profiles for both bundles. Configure the public `team_id`, `app_group_id` and provisioned `keychain_access_group` in `release/config.json`. Preserve these identifiers across releases.
3. Fetch Sparkle using `python3 tools/fetch-sparkle.py`. Run `.build/dependencies/Sparkle-2.10.0/bin/generate_keys --account mydrive-release` once to create or reuse its Keychain signing key. Configure only its public key as `sparkle_public_key`. Preserve the private key and keep a secure backup; never rotate it casually.
4. Store notarization credentials with Apple's `notarytool store-credentials` and give the profile a stable name. Enter credentials directly into Apple's tools. An App Store Connect API key in a private local file is also supported.
5. Authenticate the local GitHub CLI with `gh auth login --hostname github.com`. Git push authentication is separate from release API access. No token belongs in source, chat or a settings file.
6. Save paths and public identity names in ignored `.local/release.json`, or supply the same values as environment variables. Environment values take precedence. Run `python3 tools/release.py doctor` to identify missing setup before an expensive build.

Local settings use this shape; replace the example paths and identity with the installed credentials:

```json
{
  "MYDRIVE_SIGN_IDENTITY": "Developer ID Application: Your Name (TEAMID)",
  "MYDRIVE_HOST_PROFILE": "/absolute/path/to/MyDrive.provisionprofile",
  "MYDRIVE_PROVIDER_PROFILE": "/absolute/path/to/MyDriveProvider.provisionprofile",
  "MYDRIVE_NOTARY_KEYCHAIN_PROFILE": "mydrive-notary"
}
```

The loader accepts only documented nonsecret settings and rejects unknown keys. `MYDRIVE_SPARKLE_KEY_FILE` optionally points to a mode-0600 private export; omitting it uses Keychain account `mydrive-release`. Instead of the notarization profile, supply `MYDRIVE_NOTARY_KEY_PATH`, `MYDRIVE_NOTARY_KEY_ID` and `MYDRIVE_NOTARY_ISSUER_ID`. Store paths and identifiers, never private key contents, passwords or tokens, in the local JSON file.

## Future fixes and releases

The agent implements the fix, runs appropriate local checks, bumps the version/build, writes release notes and commits the intended source. For example:

```sh
python3 tools/release.py doctor
python3 tools/release.py bump 0.2.1 --build 3
# Write release/notes/0.2.1.md and commit the intended source.
git tag v0.2.1
git push origin main
git push origin v0.2.1
python3 tools/release.py ship
```

`ship` requires a clean checkout at the exact version tag. For a new release, it runs the publication guard and local test suite, builds in an isolated workspace, validates both provisioning profiles, signs the app and extension, notarizes, staples, archives, signs the Sparkle feed, re-extracts/verifies the app, and uploads a draft release. It checks immutable asset hashes and makes the release public only after all assets are verified. Development builds are never official releases. No NAS credentials are needed for these checks.

Source and tag publication are explicit Git steps so unrelated local changes are never automatically committed. A tag push does not build or release anything by itself. The agent uses `ship` after pushing the exact commit and tag to the configured repository.

The lower-level commands remain available:

```sh
python3 tools/release.py prepare
python3 tools/release.py verify
python3 tools/release.py publish
```

## Retrying publication

Prepared artifacts remain in ignored `dist/releases/vX.Y.Z/`. Rerun `ship` to verify and publish those exact bytes after a failed upload. It reuses an existing prepared directory; it does not replace it. Keep that directory until publication and any verification have finished, and back it up if needed. Incomplete or mismatched assets stop the command; published releases are verified without modification, and there is no clobber option. If a partial draft exists and the original local artifacts are missing, recover those original artifacts before retrying. Rebuilding a signed/notarized archive produces different bytes.

Each archive URL includes the immutable version tag. The app reads `https://github.com/lnikell/mydrive/releases/latest/download/appcast.xml`. The agent verifies the published release and reports its URL; pushing source or a tag is not evidence of a successful binary release.

Apple signing setup is still required before the first official release. The first signed release also needs an actual installed old-to-new update trial covering Finder locations, saved credentials, offline files, status indicators, offload and removal. Local tests verify release guards and signature handling; they do not replace that qualification.
