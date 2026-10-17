#!/usr/bin/env python3
"""Prepare, verify and publish signed MyDrive releases using the same local/CI path."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from release_github import GitHub
from release_support import (ROOT, SPARKLE, VERSION_RE, ReleaseError, artifact_records,
                             configuration_problems, digest, release_config, run,
                             source_commit, validate_appcast, validate_manifest, version_info)


def signing_arguments():
    key = os.environ.get("MYDRIVE_SPARKLE_KEY_FILE")
    if key:
        path = Path(key).resolve()
        if not path.is_file() or path.stat().st_mode & 0o077 or not 1 <= path.stat().st_size <= 1024:
            raise ReleaseError("MYDRIVE_SPARKLE_KEY_FILE must be an existing private file (mode 0600).")
        return ["--ed-key-file", str(path)]
    return ["--account", "mydrive-release"]


def sparkle_path():
    return Path(run([sys.executable, ROOT / "tools/fetch-sparkle.py"], capture=True))


def verify_signing_key(sparkle, config):
    arguments = signing_arguments()
    if arguments[0] == "--ed-key-file":
        with Path(arguments[1]).open("rb") as source:
            if os.fstat(source.fileno()).st_mode & 0o077:
                raise ReleaseError("The Sparkle key file must remain private (mode 0600).")
            secret = source.read(1025)
        if not 1 <= len(secret) <= 1024:
            raise ReleaseError("The Sparkle key file exceeds its supported size.")
        executable = ROOT / ".build/release-tools/check-sparkle-key"
        executable.parent.mkdir(parents=True, exist_ok=True)
        run(["xcrun", "swiftc", "-O", ROOT / "tools/check-sparkle-key.swift", "-o", executable])
        # The private seed travels through stdin, never argv or captured output.
        result = subprocess.run([str(executable), config["sparkle_public_key"]], input=secret,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        if result.returncode:
            raise ReleaseError("The Sparkle private key does not match the configured public key.")
    else:
        public = run([sparkle / "bin/generate_keys", "--account", "mydrive-release", "-p"], capture=True)
        if public != config["sparkle_public_key"]:
            raise ReleaseError("The Keychain Sparkle key does not match release/config.json.")


def doctor(config):
    problems = configuration_problems(config)
    if platform.machine() != "arm64":
        problems.append("This release channel currently builds Apple silicon (arm64) only.")
    for command in ("git", "xcrun", "codesign", "ditto", "cargo", "gh"):
        if not shutil.which(command):
            problems.append(f"Install {command} before releasing.")
    if not (ROOT / ".git").exists():
        problems.append("Initialize Git and configure the intended GitHub origin.")
    if not os.environ.get("MYDRIVE_SIGN_IDENTITY") or os.environ["MYDRIVE_SIGN_IDENTITY"] == "-":
        problems.append("Set MYDRIVE_SIGN_IDENTITY to a Developer ID Application signing identity.")
    for name in ("MYDRIVE_HOST_PROFILE", "MYDRIVE_PROVIDER_PROFILE"):
        if not Path(os.environ.get(name, "/nonexistent")).is_file():
            problems.append(f"Set {name} to its Developer ID provisioning profile.")
    if not os.environ.get("MYDRIVE_NOTARY_KEYCHAIN_PROFILE") and not all(os.environ.get(x) for x in (
            "MYDRIVE_NOTARY_KEY_PATH", "MYDRIVE_NOTARY_KEY_ID", "MYDRIVE_NOTARY_ISSUER_ID")):
        problems.append("Configure a notarytool Keychain profile or App Store Connect API key credentials.")
    return problems


def notarize(app, folder, config):
    submission = folder / "notarization-input.zip"
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission])
    arguments = ["xcrun", "notarytool", "submit", submission, "--wait", "--output-format", "json"]
    profile = os.environ.get("MYDRIVE_NOTARY_KEYCHAIN_PROFILE")
    if profile:
        arguments += ["--keychain-profile", profile]
    else:
        arguments += ["--key", os.environ["MYDRIVE_NOTARY_KEY_PATH"], "--key-id", os.environ["MYDRIVE_NOTARY_KEY_ID"],
                      "--issuer", os.environ["MYDRIVE_NOTARY_ISSUER_ID"]]
    report = json.loads(run(arguments, capture=True, timeout=2400))
    if report.get("status") != "Accepted":
        raise ReleaseError(f"Apple notarization was not accepted (submission {report.get('id', 'unavailable')}).")
    run(["xcrun", "stapler", "staple", app])
    verify_app(app, config)
    submission.unlink()


def verify_app(app, config):
    run(["codesign", "--verify", "--deep", "--strict", app])
    for bundle, identifier in ((app, config["app_bundle_id"]),
                               (app / "Contents/PlugIns/MyDriveProvider.appex", config["provider_bundle_id"])):
        signing = subprocess.run(["codesign", "--display", "--verbose=4", str(bundle)],
                                 capture_output=True, text=True, timeout=30)
        if signing.returncode or f"TeamIdentifier={config['team_id']}" not in signing.stderr.splitlines():
            raise ReleaseError("The app and provider must be signed by the configured Apple team.")
        entitlement_data = subprocess.run(["codesign", "--display", "--entitlements", ":-", str(bundle)],
                                          capture_output=True, timeout=30)
        if entitlement_data.returncode:
            raise ReleaseError("Could not inspect the signed app/provider entitlements.")
        entitlements = plistlib.loads(entitlement_data.stdout)
        if entitlements.get("com.apple.application-identifier") != config["team_id"] + "." + identifier \
                or entitlements.get("keychain-access-groups") != [config["keychain_access_group"]] \
                or entitlements.get("com.apple.security.application-groups") != [config["app_group_id"]]:
            raise ReleaseError("The signed app/provider identity, App Group or Keychain access group differs from configuration.")
    run(["xcrun", "stapler", "validate", app])
    run(["spctl", "--assess", "--type", "execute", app])


def verify_signatures(folder, sparkle, config, version):
    verify_signing_key(sparkle, config)
    arguments = signing_arguments()
    run([sparkle / "bin/sign_update", *arguments, "--verify", folder / "appcast.xml"], capture=True)
    item = ET.parse(folder / "appcast.xml").find("./channel/item")
    for element, filename in ((item.find("enclosure"), f"MyDrive-{version['version']}-arm64.zip"),
                              (item.find(f"{{{SPARKLE}}}releaseNotesLink"), f"MyDrive-{version['version']}-arm64.md")):
        signature = element.get(f"{{{SPARKLE}}}edSignature")
        if not signature:
            raise ReleaseError(f"Missing signed artifact: {filename}")
        run([sparkle / "bin/sign_update", *arguments, "--verify", folder / filename, signature], capture=True)


def check_archive(folder, config, version):
    with tempfile.TemporaryDirectory(prefix="mydrive-release-verification-") as temporary:
        destination = Path(temporary)
        run(["ditto", "-x", "-k", folder / f"MyDrive-{version['version']}-arm64.zip", destination])
        app = destination / "MyDrive.app"
        if {p.name for p in destination.iterdir()} - {"MyDrive.app", "__MACOSX"}:
            raise ReleaseError("The archive must contain only MyDrive.app.")
        verify_app(app, config)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        expected = {"CFBundleIdentifier": config["app_bundle_id"], "CFBundleVersion": version["build"],
                    "CFBundleShortVersionString": version["version"], "SUPublicEDKey": config["sparkle_public_key"],
                    "SUFeedURL": f"https://github.com/{config['repository']}/releases/latest/download/appcast.xml",
                    "SURequireSignedFeed": True, "MyDriveDevelopmentBuild": False}
        if any(info.get(k) != v for k, v in expected.items()):
            raise ReleaseError("The packaged application metadata does not match the intended release.")


def prepare(config, version):
    tag = "v" + version["version"]
    final = ROOT / "dist/releases" / tag
    if final.exists():
        raise ReleaseError("Prepared output already exists. Verify/publish it, or explicitly move it aside before rebuilding.")
    issues = doctor(config)
    if issues:
        raise ReleaseError("Release setup is incomplete:\n- " + "\n- ".join(issues))
    commit = source_commit(tag)
    notes = ROOT / f"release/notes/{version['version']}.md"
    if not notes.is_file() or not notes.read_text().strip():
        raise ReleaseError(f"Write release notes in {notes.relative_to(ROOT)} before releasing.")
    sparkle = sparkle_path()
    signing_arguments()
    verify_signing_key(sparkle, config)
    print("Running release checks…", flush=True)
    run(["bash", ROOT / "tools/check.sh"])
    final.parent.mkdir(parents=True, exist_ok=True)
    # No public artifact directory exists until every local validation succeeds.
    workspace_parent = ROOT / ".build/release-work"
    workspace_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="build-", dir=workspace_parent) as workspace, \
            tempfile.TemporaryDirectory(prefix="mydrive-release-stage-", dir=final.parent) as temporary:
        workspace = Path(workspace)
        print("Building the signed app in an isolated release workspace…", flush=True)
        run(["bash", ROOT / "tools/build-macos.sh"], env=dict(os.environ, MYDRIVE_RELEASE="1", MYDRIVE_ARCH="arm64",
            MYDRIVE_BUILD_DIR=str(workspace / "build"), MYDRIVE_DIST_DIR=str(workspace / "output")))
        folder = Path(temporary)
        app = workspace / "output/MyDrive.app"
        print("Submitting to Apple and stapling its ticket…", flush=True)
        notarize(app, folder, config)
        archive = folder / f"MyDrive-{version['version']}-arm64.zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
        archive.with_suffix(".md").write_text(notes.read_text())
        prefix = f"https://github.com/{config['repository']}/releases/download/{tag}/"
        print("Generating and verifying the signed update feed…", flush=True)
        run([sparkle / "bin/generate_appcast", *signing_arguments(), "--maximum-versions", "1", "--maximum-deltas", "0",
             "--download-url-prefix", prefix, "--release-notes-url-prefix", prefix,
             "--link", f"https://github.com/{config['repository']}", folder])
        validate_appcast(folder / "appcast.xml", folder, config, version)
        verify_signatures(folder, sparkle, config, version)
        check_archive(folder, config, version)
        hashes = "".join(f"{digest(p)}  {p.name}\n" for p in sorted(folder.iterdir()) if p.is_file())
        (folder / "SHA256SUMS").write_text(hashes)
        manifest = dict(schema_version=1, repository=config["repository"], version=version["version"],
                        build=version["build"], tag=tag, commit=commit, architecture="arm64", artifacts=artifact_records(folder))
        (folder / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        validate_manifest(folder, config, version, commit)
        if source_commit(tag) != commit:
            raise ReleaseError("Source changed while preparing the release.")
        folder.rename(final)
    print(f"Prepared and verified {final}", flush=True)


def bump(version, build):
    previous = version_info()
    if not VERSION_RE.fullmatch(version) or tuple(map(int, version.split("."))) <= tuple(map(int, previous["version"].split("."))):
        raise ReleaseError("The new version must be a greater major.minor.patch version.")
    if build <= int(previous["build"]):
        raise ReleaseError("The build number must increase.")
    (ROOT / "release/version.json").write_text(json.dumps({"version": version, "build": str(build)}, indent=2) + "\n")
    print(f"Set version {version} ({build}). Write release notes, commit, and tag before prepare.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("doctor", "prepare", "verify", "publish"):
        commands.add_parser(name)
    change = commands.add_parser("bump")
    change.add_argument("version")
    change.add_argument("--build", type=int, required=True)
    args = parser.parse_args()
    if args.command == "bump":
        bump(args.version, args.build)
        return
    config, version = release_config(), version_info()
    if args.command == "doctor":
        issues = doctor(config)
        print("\n".join("- " + x for x in issues) if issues else "Release prerequisites are configured; prepare validates actual credentials and profiles.")
        if issues:
            raise SystemExit(1)
    elif args.command == "prepare":
        prepare(config, version)
    else:
        issues = configuration_problems(config)
        if issues:
            raise ReleaseError("Release configuration is incomplete:\n- " + "\n- ".join(issues))
        commit = source_commit("v" + version["version"])
        folder = ROOT / "dist/releases" / ("v" + version["version"])
        manifest = validate_manifest(folder, config, version, commit)
        verify_signatures(folder, sparkle_path(), config, version)
        check_archive(folder, config, version)
        if args.command == "verify":
            print("Release archive, feed, signatures, notarization and source provenance verified.")
        else:
            notes = (ROOT / f"release/notes/{version['version']}.md").read_text()
            print(GitHub(config["repository"]).publish(folder, manifest, notes))


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError, ET.ParseError, subprocess.TimeoutExpired) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        sys.exit(1)
