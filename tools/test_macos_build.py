#!/usr/bin/env python3
"""Local build-policy tests; no signing identity, Keychain or network access."""
import base64
import copy
import datetime
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import macos_build as build
from release_support import ReleaseError, release_config, version_info

spec = importlib.util.spec_from_file_location("fetch_sparkle", Path(__file__).with_name("fetch-sparkle.py"))
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)


class BuildPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mydrive-build-policy-")
        self.root = Path(self.temporary.name)
        (self.root / "release").mkdir()
        self.config, self.version = build.configuration()
        self.config.update(repository="example/mydrive", team_id="ABCDE12345",
                           keychain_access_group="ABCDE12345.shared",
                           sparkle_public_key=base64.b64encode(bytes(range(32))).decode())
        (self.root / "release/config.json").write_text(json.dumps(self.config))
        (self.root / "release/version.json").write_text(json.dumps(self.version))
        (self.root / "config").mkdir()
        self.test_target = dict(host="192.0.2.1:445", share="mydrive-test", username="mydrive-test")
        (self.root / "config/nas-test.example.json").write_text(json.dumps(self.test_target))
        self.certificate = b"synthetic certificate fixture"
        self.digest = hashlib.sha1(self.certificate).hexdigest().upper()

    def tearDown(self):
        self.temporary.cleanup()

    def profile(self, bundle):
        return dict(ExpirationDate=datetime.datetime(2099, 1, 1), TeamIdentifier=[self.config["team_id"]],
                    ProvisionsAllDevices=True, DeveloperCertificates=[self.certificate], Entitlements={
                        "com.apple.application-identifier": self.config["team_id"] + "." + bundle,
                        "keychain-access-groups": [self.config["team_id"] + ".*"],
                        "com.apple.security.application-groups": [self.config["app_group_id"]]})

    def framework(self):
        sparkle = self.root / "dependency"
        binary = sparkle / "Sparkle.framework/Versions/B/Sparkle"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"fixture")
        (binary.parent.parent / "Current").symlink_to("B")
        (sparkle / "Sparkle.framework/Sparkle").symlink_to("Versions/Current/Sparkle")
        return sparkle

    def test_config_rejects_malformed_versions_repositories_and_keys(self):
        self.assertEqual(build.configuration(self.root)[1], self.version)
        for field, value in [("repository", "owner/repo/extra"), ("sparkle_public_key", "not-base64"),
                             ("repository", "owner/.."), ("team_id", "guess"),
                             ("keychain_access_group", "TEAM.*"), ("app_group_id", "../outside"),
                             ("schema_version", 99), ("schema_version", True)]:
            config = dict(self.config, **{field: value})
            (self.root / "release/config.json").write_text(json.dumps(config))
            with self.assertRaises(ValueError):
                build.configuration(self.root)

    def test_build_and_release_share_canonical_configuration_and_versions(self):
        (self.root / "release/version.json").write_text(json.dumps({"version": "0.2.0", "build": 2}))
        self.assertEqual(build.configuration(self.root), (release_config(self.root), version_info(self.root)))
        self.assertEqual(build.configuration(self.root)[1]["build"], "2")
        for version in ({"version": "0.02.0", "build": "2"}, {"version": "0.2.0", "build": True}, []):
            (self.root / "release/version.json").write_text(json.dumps(version))
            with self.assertRaises(ReleaseError):
                version_info(self.root)
            with self.assertRaises(ValueError):
                build.configuration(self.root)

    def test_explicit_release_refuses_ad_hoc_signing_before_any_bundle_mutation(self):
        app, output = self.root / "MyDrive.app", self.root / "build"
        with self.assertRaisesRegex(ValueError, "release build requires"):
            build.prepare(app, output, self.root / "unused-dependency", "-", root=self.root,
                          environment={"MYDRIVE_RELEASE": "1"})
        self.assertFalse(app.exists())
        self.assertFalse(output.exists())

    def test_production_cannot_fall_back_to_missing_configuration(self):
        build.production_configuration(self.config)
        for field in ("repository", "team_id", "keychain_access_group", "sparkle_public_key"):
            with self.assertRaises(ValueError):
                build.production_configuration(dict(self.config, **{field: None}))

    def test_identity_requires_exact_developer_id_application(self):
        name = "Developer ID Application: Synthetic (ABCDE12345)"
        listing = f'1) {self.digest} "{name}"\n'
        self.assertEqual(build.signing_identity(name, listing), self.digest)
        self.assertEqual(build.signing_identity(self.digest.lower(), listing), self.digest)
        for request, text in [("Unknown", listing), (name, listing + listing),
                              ("Apple Development: Synthetic", f'{self.digest} "Apple Development: Synthetic"')]:
            with self.assertRaises(ValueError):
                build.signing_identity(request, text)

    def test_profiles_require_team_bundle_certificate_distribution_and_both_groups(self):
        profile = self.profile(self.config["app_bundle_id"])
        build.validate_profile(profile, self.config, self.config["app_bundle_id"], self.digest)
        failures = []
        for field, value in [("ExpirationDate", datetime.datetime(2000, 1, 1)), ("TeamIdentifier", ["OTHERTEAM1"]),
                             ("DeveloperCertificates", [b"other"]), ("ProvisionsAllDevices", False)]:
            failures.append(dict(profile, **{field: value}))
        for field, value in [("com.apple.application-identifier", "ABCDE12345.wrong"),
                             ("keychain-access-groups", ["OTHER.*"]),
                             ("com.apple.security.application-groups", ["group.other"]),
                             ("com.apple.security.get-task-allow", True)]:
            candidate = copy.deepcopy(profile)
            candidate["Entitlements"][field] = value
            failures.append(candidate)
        for candidate in failures:
            with self.assertRaises(ValueError):
                build.validate_profile(candidate, self.config, self.config["app_bundle_id"], self.digest)

    def test_development_bundle_has_no_feed_or_public_key_and_preserves_framework_links(self):
        app, output = self.root / "MyDrive.app", self.root / "build"
        build.prepare(app, output, self.framework(), "-", root=self.root)
        host = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        provider = plistlib.loads((app / "Contents/PlugIns/MyDriveProvider.appex/Contents/Info.plist").read_bytes())
        self.assertNotIn("SUFeedURL", host)
        self.assertNotIn("SUPublicEDKey", host)
        self.assertTrue(host["MyDriveDevelopmentBuild"])
        self.assertEqual(host["MyDriveDevelopmentConnection"], self.test_target)
        self.assertEqual(provider["MyDriveDevelopmentConnection"], self.test_target)
        self.assertEqual(host["MyDriveDevelopmentCredentialBuildID"], provider["MyDriveDevelopmentCredentialBuildID"])
        self.assertTrue((app / "Contents/Frameworks/Sparkle.framework/Sparkle").is_symlink())
        self.assertEqual(host["CFBundleVersion"], provider["CFBundleVersion"])
        self.assertIs(provider["NSExtension"]["NSExtensionFileProviderWantsFlattenedPackages"], False)

    def test_local_development_target_is_injected_but_never_shipped_in_production(self):
        local = self.root / ".local"
        local.mkdir()
        target = dict(self.test_target, host="192.0.2.2:445", username="local-test")
        (local / "nas-test.json").write_text(json.dumps(target))
        app = self.root / "MyDrive.app"
        build.prepare(app, self.root / "build", self.framework(), "-", root=self.root)
        for bundle in (app, app / "Contents/PlugIns/MyDriveProvider.appex"):
            self.assertEqual(plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["MyDriveDevelopmentConnection"], target)

    def test_production_bundle_embeds_both_profiles_and_scopes_updater_to_host(self):
        app, output = self.root / "MyDrive.app", self.root / "build"
        environment = {}
        for variable, bundle in [("MYDRIVE_HOST_PROFILE", self.config["app_bundle_id"]),
                                  ("MYDRIVE_PROVIDER_PROFILE", self.config["provider_bundle_id"])]:
            path = self.root / (variable + ".provisionprofile")
            path.write_bytes(plistlib.dumps(self.profile(bundle)))
            environment[variable] = str(path)
        def command(arguments, **kwargs):
            if arguments[1] == "find-identity":
                return SimpleNamespace(stdout=f'{self.digest} "Developer ID Application: Synthetic"')
            return SimpleNamespace(stdout=Path(arguments[-1]).read_bytes())
        with patch.object(build.subprocess, "run", side_effect=command):
            build.prepare(app, output, self.framework(), self.digest, root=self.root, environment=environment)
        host = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        provider = plistlib.loads((app / "Contents/PlugIns/MyDriveProvider.appex/Contents/Info.plist").read_bytes())
        entitlements = plistlib.loads((output / "entitlements.plist").read_bytes())
        extension_entitlements = plistlib.loads((output / "provider-entitlements.plist").read_bytes())
        self.assertEqual(host["SUFeedURL"], "https://github.com/example/mydrive/releases/latest/download/appcast.xml")
        self.assertTrue(host["SURequireSignedFeed"] and host["SUVerifyUpdateBeforeExtraction"])
        self.assertNotIn("SUFeedURL", provider)
        self.assertIs(provider["NSExtension"]["NSExtensionFileProviderWantsFlattenedPackages"], False)
        self.assertNotIn("MyDriveDevelopmentConnection", host)
        self.assertNotIn("MyDriveDevelopmentConnection", provider)
        self.assertNotIn("SUEnableDownloaderService", host)
        self.assertEqual(entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"],
                         [self.config["app_bundle_id"] + "-spks", self.config["app_bundle_id"] + "-spki"])
        self.assertNotIn("com.apple.security.temporary-exception.mach-lookup.global-name", extension_entitlements)
        self.assertNotIn("com.apple.security.temporary-exception.files.absolute-path.read-write", entitlements)
        self.assertTrue((app / "Contents/embedded.provisionprofile").exists())
        self.assertTrue((app / "Contents/PlugIns/MyDriveProvider.appex/Contents/embedded.provisionprofile").exists())

    def test_signing_is_inside_out_and_never_uses_deep_for_signing(self):
        commands = build.signing_commands(self.root / "MyDrive.app", self.root / "build", "synthetic identity")
        for command in commands[:-1]:
            self.assertIn("runtime", command)
            self.assertIn("--timestamp", command)
            self.assertNotIn("--deep", command)
        self.assertTrue(commands[0][-1].endswith("Installer.xpc"))
        self.assertTrue(commands[-2][-1].endswith("MyDrive.app"))
        self.assertEqual(commands[-1][:4], ["codesign", "--verify", "--deep", "--strict"])

    def test_bundle_replacement_preserves_old_app_when_install_fails(self):
        app, destination = self.root / "stage.app", self.root / "dist/MyDrive.app"
        app.mkdir()
        destination.mkdir(parents=True)
        (app / "new").write_text("new")
        (destination / "old").write_text("old")
        original = build.os.replace
        def replacement(source, target):
            if source == app:
                raise OSError("synthetic installation failure")
            return original(source, target)
        with patch.object(build.os, "replace", side_effect=replacement), self.assertRaises(OSError):
            build.publish(app, destination)
        self.assertEqual((destination / "old").read_text(), "old")
        self.assertTrue((app / "new").exists())
        build.publish(app, destination)
        self.assertTrue((destination / "new").exists())
        self.assertFalse((destination / "old").exists())


class DependencyTests(unittest.TestCase):
    def test_archive_hash_and_length_are_both_required(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "archive"
            path.write_bytes(b"synthetic")
            with patch.object(fetch, "SIZE", 9), patch.object(fetch, "SHA256", hashlib.sha256(b"synthetic").hexdigest()):
                fetch.verify_archive(path)
                path.write_bytes(b"tampered!")
                with self.assertRaises(ValueError):
                    fetch.verify_archive(path)

    def test_archive_traversal_is_rejected_and_framework_links_survive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, rejected in [("../outside", True), ("framework/Versions/B/file", False)]:
                archive = root / "archive.tar.xz"
                with tarfile.open(archive, "w:xz") as output:
                    member = tarfile.TarInfo(name)
                    member.size = 3
                    output.addfile(member, io.BytesIO(b"abc"))
                    if not rejected:
                        link = tarfile.TarInfo("framework/Versions/Current")
                        link.type = tarfile.SYMTYPE
                        link.linkname = "B"
                        output.addfile(link)
                destination = root / "extracted"
                destination.mkdir(exist_ok=True)
                if rejected:
                    with self.assertRaises(ValueError):
                        fetch.extract_archive(archive, destination)
                else:
                    fetch.extract_archive(archive, destination)
                    self.assertEqual((destination / "framework/Versions/Current/file").read_bytes(), b"abc")


if __name__ == "__main__":
    unittest.main()
