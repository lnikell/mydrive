#!/usr/bin/env python3
"""Bundle metadata, provisioning checks and inside-out macOS code signing."""
import argparse
import datetime
import fnmatch
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

from release_support import ReleaseError, configuration_problems, release_config, version_info
from nas_test_config import load_nas_test_config

ROOT = Path(__file__).resolve().parents[1]


def configuration(root=ROOT):
    try:
        return release_config(root), version_info(root)
    except ReleaseError as error:
        raise ValueError(str(error)) from error


def production_configuration(config):
    problems = configuration_problems(config)
    if problems:
        raise ValueError(" ".join(problems))
    group = config.get("keychain_access_group")
    if not isinstance(group, str) or not group.startswith(config["team_id"] + ".") or "*" in group:
        raise ValueError("Configure an explicit provisioned shared Keychain access group for this team")


def signing_identity(requested, listing):
    identities = re.findall(r'\b([A-Fa-f0-9]{40})\s+"([^"]+)"', listing)
    matches = [(digest.upper(), name) for digest, name in identities
               if requested.upper() == digest.upper() or requested == name]
    if len(matches) != 1 or not matches[0][1].startswith("Developer ID Application:"):
        raise ValueError("Production signing requires one valid Developer ID Application identity with its private key")
    return matches[0][0]


def validate_profile(profile, config, bundle_id, certificate, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime):
        raise ValueError("Provisioning profile has no expiration date")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=datetime.timezone.utc)
    entitlements = profile.get("Entitlements", {})
    app_id = entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier"))
    expected = config["team_id"] + "." + bundle_id
    if expires <= now or config["team_id"] not in profile.get("TeamIdentifier", []) or app_id != expected:
        raise ValueError("Provisioning profile is expired or does not match the configured team and bundle")
    if profile.get("ProvisionsAllDevices") is not True or entitlements.get("com.apple.security.get-task-allow") is True:
        raise ValueError("Use a Developer ID distribution provisioning profile, not a development profile")
    certificates = profile.get("DeveloperCertificates", [])
    if not any(hashlib.sha1(data).hexdigest().upper() == certificate for data in certificates if isinstance(data, bytes)):
        raise ValueError("Provisioning profile does not authorize the selected signing certificate")
    for key, requested in (("keychain-access-groups", config["keychain_access_group"]),
                           ("com.apple.security.application-groups", config["app_group_id"])):
        allowed = entitlements.get(key, [])
        if not isinstance(allowed, list) or not any(isinstance(pattern, str) and fnmatch.fnmatchcase(requested, pattern) for pattern in allowed):
            raise ValueError(f"Provisioning profile does not authorize {key}")


def prepare(app, build, sparkle, identity, root=ROOT, environment=None):
    environment = os.environ if environment is None else environment
    config, version = configuration(root)
    development = identity == "-"
    if development and environment.get("MYDRIVE_RELEASE") == "1":
        raise ValueError("A release build requires a Developer ID Application signing identity; ad-hoc signing is development only")
    extension = app / "Contents/PlugIns/MyDriveProvider.appex"
    profiles = []
    if not development:
        production_configuration(config)
        listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                                 check=True, capture_output=True, text=True).stdout
        certificate = signing_identity(identity, listing)
        for variable, bundle in (("MYDRIVE_HOST_PROFILE", config["app_bundle_id"]),
                                 ("MYDRIVE_PROVIDER_PROFILE", config["provider_bundle_id"])):
            if not environment.get(variable):
                raise ValueError(f"Set {variable} to the matching Developer ID provisioning profile")
            path = Path(environment[variable]).expanduser().resolve(strict=True)
            data = subprocess.run(["security", "cms", "-D", "-i", str(path)],
                                  check=True, capture_output=True).stdout
            validate_profile(plistlib.loads(data), config, bundle, certificate)
            profiles.append(path)
    common = dict(CFBundleVersion=version["build"], CFBundleShortVersionString=version["version"], LSMinimumSystemVersion="15.0")
    host = dict(common, CFBundleIdentifier=config["app_bundle_id"], CFBundleName="MyDrive", CFBundleExecutable="MyDrive",
                CFBundlePackageType="APPL", NSPrincipalClass="NSApplication", NSHighResolutionCapable=True,
                NSLocalNetworkUsageDescription="MyDrive connects to your NAS to show files in Finder and keep selected files offline.",
                NSBonjourServices=["_smb._tcp"], MyDriveDevelopmentBuild=development,
                MyDriveAppGroupID=config["app_group_id"])
    provider = dict(common, CFBundleIdentifier=config["provider_bundle_id"], CFBundleName="MyDriveProvider",
                    CFBundleExecutable="MyDriveProvider", CFBundlePackageType="XPC!", MyDriveDevelopmentBuild=development,
                    MyDriveAppGroupID=config["app_group_id"], NSExtension={
                        "NSExtensionPointIdentifier": "com.apple.fileprovider-nonui",
                        "NSExtensionPrincipalClass": "FileProviderExtension",
                        "NSExtensionFileProviderDocumentGroup": config["app_group_id"],
                        "NSExtensionFileProviderSupportsEnumeration": True,
                        "NSExtensionFileProviderActions": [
                            {"NSExtensionFileProviderActionIdentifier": "local.mydrive.keepDownloaded",
                             "NSExtensionFileProviderActionName": "Keep Downloaded",
                             "NSExtensionFileProviderActionActivationRule": "fileproviderItems.@count > 0 AND fileproviderItems.@count <= 1000"},
                            {"NSExtensionFileProviderActionIdentifier": "local.mydrive.freeUpSpace",
                             "NSExtensionFileProviderActionName": "Free Up Space",
                             "NSExtensionFileProviderActionActivationRule": "fileproviderItems.@count > 0 AND fileproviderItems.@count <= 1000"}],
                        "NSExtensionFileProviderDownloadPipelineDepth": 2})
    entitlements = {"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True,
                    "com.apple.security.files.user-selected.read-write": True,
                    "com.apple.security.application-groups": [config["app_group_id"]]}
    provider_entitlements = dict(entitlements)
    if development:
        build_id = str(uuid.uuid4())
        development_connection = load_nas_test_config(root)
        for info in (host, provider):
            info["MyDriveDevelopmentStoragePath"] = str(root / ".runtime")
            info["MyDriveDevelopmentCredentialBuildID"] = build_id
            info["MyDriveDevelopmentConnection"] = development_connection
        for value in (entitlements, provider_entitlements):
            value["com.apple.security.temporary-exception.files.absolute-path.read-write"] = [str(root / ".runtime") + "/"]
    else:
        for info in (host, provider):
            info["MyDriveKeychainAccessGroup"] = config["keychain_access_group"]
        for bundle, value in ((config["app_bundle_id"], entitlements), (config["provider_bundle_id"], provider_entitlements)):
            value["keychain-access-groups"] = [config["keychain_access_group"]]
            value["com.apple.application-identifier"] = config["team_id"] + "." + bundle
            value["com.apple.developer.team-identifier"] = config["team_id"]
        host.update(SUFeedURL=f"https://github.com/{config['repository']}/releases/latest/download/appcast.xml",
                    SUPublicEDKey=config["sparkle_public_key"], SUEnableAutomaticChecks=True,
                    SUAutomaticallyUpdate=True, SUEnableInstallerLauncherService=True,
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
        # Sparkle's two documented names are host-specific. The File Provider
        # receives neither these exceptions nor a separate updater.
        entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] = [
            config["app_bundle_id"] + "-spks", config["app_bundle_id"] + "-spki"]
    outputs = ((app / "Contents/Info.plist", host), (extension / "Contents/Info.plist", provider),
               (build / "entitlements.plist", entitlements), (build / "provider-entitlements.plist", provider_entitlements),
               (build / "helper-entitlements.plist", {"com.apple.security.app-sandbox": True, "com.apple.security.inherit": True}))
    for path, value in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))
    for bundle, profile in zip((app, extension), profiles):
        shutil.copyfile(profile, bundle / "Contents/embedded.provisionprofile")
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    shutil.copytree(sparkle / "Sparkle.framework", frameworks / "Sparkle.framework", symlinks=True)


def signing_commands(app, build, identity):
    config, _ = configuration()
    extension = app / "Contents/PlugIns/MyDriveProvider.appex"
    framework = app / "Contents/Frameworks/Sparkle.framework"
    nested = framework / "Versions/B"
    base = ["codesign", "--force", "--sign", identity]
    base += ["--timestamp=none"] if identity == "-" else ["--options", "runtime", "--timestamp"]
    commands = []
    for path, extra in (
        (nested / "XPCServices/Installer.xpc", []),
        (nested / "XPCServices/Downloader.xpc", ["--preserve-metadata=entitlements"]),
        (nested / "Autoupdate", []), (nested / "Updater.app", []), (framework, []),
        (app / "Contents/Helpers/nas-transport", ["--identifier", config["app_bundle_id"] + ".transport", "--entitlements", str(build / "helper-entitlements.plist")]),
        (extension / "Contents/Helpers/nas-transport", ["--identifier", config["provider_bundle_id"] + ".transport", "--entitlements", str(build / "helper-entitlements.plist")]),
        (extension, ["--entitlements", str(build / "provider-entitlements.plist")]),
        (app, ["--entitlements", str(build / "entitlements.plist")]),
    ):
        commands.append(base + extra + [str(path)])
    commands.append(["codesign", "--verify", "--deep", "--strict", str(app)])
    return commands


def publish(app, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise ValueError("Refusing to replace a symbolic-link app destination")
    backup = Path(tempfile.mkdtemp(prefix="previous-app-", dir=destination.parent)) / destination.name
    installed = False
    try:
        if destination.exists():
            os.replace(destination, backup)
        try:
            os.replace(app, destination)
            installed = True
        except BaseException:
            if backup.exists():
                try:
                    os.replace(backup, destination)
                except OSError as error:
                    raise OSError(f"App replacement failed; previous app retained at {backup}") from error
            raise
    finally:
        if installed or not backup.exists():
            shutil.rmtree(backup.parent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "sign", "publish"))
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--build", type=Path)
    parser.add_argument("--sparkle", type=Path)
    parser.add_argument("--identity", default="-")
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            if args.build is None or args.sparkle is None:
                raise ValueError("prepare requires --build and --sparkle")
            prepare(args.app, args.build, args.sparkle, args.identity)
        elif args.action == "sign":
            if args.build is None:
                raise ValueError("sign requires --build")
            for command in signing_commands(args.app, args.build, args.identity):
                subprocess.run(command, check=True)
        else:
            if args.destination is None:
                raise ValueError("publish requires --destination")
            publish(args.app, args.destination)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"macOS build failed: {error}\n")


if __name__ == "__main__":
    main()
