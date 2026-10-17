"""Credential-free regressions at the signing, publication and packaging seams."""
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release
from release_github import GitHub
from release_support import ReleaseError, SPARKLE, MANIFEST_SCHEMA, release_compatibility, validate_manifest
import third_party_notices as notices


CONFIG = dict(schema_version=1, repository="example/MyDrive", team_id="ABC1234567",
              app_bundle_id="local.mydrive.app", provider_bundle_id="local.mydrive.app.provider",
              app_group_id="group.local.mydrive", keychain_access_group="ABC1234567.local.mydrive",
              sparkle_public_key=base64.b64encode(b"p" * 32).decode())
VERSION = {"version": "0.2.0", "build": "2"}
COMMIT = "a" * 40


def signed_entitlements(identifier):
    return {"com.apple.application-identifier": CONFIG["team_id"] + "." + identifier,
            "keychain-access-groups": [CONFIG["keychain_access_group"]],
            "com.apple.security.application-groups": [CONFIG["app_group_id"]]}


class ReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mydrive-release-guards-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "MyDrive.app"
        self.provider = self.app / "Contents/PlugIns/MyDriveProvider.appex"
        # Use the actual checked-in icon; only signing/account commands below
        # are mocked, while resource bytes and plist checks remain real.
        self.icon = (release.ROOT / "MacApp/Resources/MyDrive.icns").read_bytes()
        self.source_icon = self.root / "MacApp/Resources/MyDrive.icns"
        self.source_icon.parent.mkdir(parents=True)
        self.source_icon.write_bytes(self.icon)
        components = [dict(kind=kind, name=name, version=number, license=license_name,
                           files=[("LICENSE", b"Complete synthetic license text for a credential-free test.\n")])
                      for kind, name, number, license_name in (("project", "MyDrive", VERSION["version"], "MIT"),
                           ("cargo", "dependency", "1.0.0", "MIT"), ("sparkle", "Sparkle", "2.10.0", "See included LICENSE"))]
        data = notices.render(components, VERSION["version"])
        for bundle in (self.app, self.provider):
            path = bundle / notices.RESOURCE
            path.parent.mkdir(parents=True)
            path.write_bytes(data)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": VERSION["version"], "CFBundleIconFile": "MyDrive.icns"}))
            (bundle / "Contents/Resources/MyDrive.icns").write_bytes(self.icon)

    def verify_with_inspections(self, *, teams=None, entitlements=None):
        records = {
            self.app: signed_entitlements(CONFIG["app_bundle_id"]),
            self.provider: signed_entitlements(CONFIG["provider_bundle_id"]),
        }
        records.update(entitlements or {})
        inspected = set()
        completed = []

        def codesign(arguments, **kwargs):
            bundle = Path(arguments[-1])
            self.assertIn(bundle, records)
            self.assertEqual(arguments[0:2], ["codesign", "--display"])
            if "--verbose=4" in arguments:
                team = (teams or {}).get(bundle, CONFIG["team_id"])
                return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="TeamIdentifier=" + team + "\n")
            self.assertIn("--entitlements", arguments)
            inspected.add(bundle)
            return subprocess.CompletedProcess(arguments, 0, stdout=plistlib.dumps(records[bundle]), stderr=b"")

        with patch.object(release, "ROOT", self.root), \
                patch.object(release, "run", side_effect=lambda arguments: completed.append(arguments)), \
                patch.object(release.subprocess, "run", side_effect=codesign):
            release.verify_app(self.app, CONFIG)
        return inspected, completed

    def test_both_host_and_provider_signed_identities_are_required(self):
        inspected, completed = self.verify_with_inspections()
        self.assertEqual(inspected, {self.app, self.provider})
        self.assertTrue(any(command[:3] == ["xcrun", "stapler", "validate"] for command in completed))
        self.assertTrue(any(command[0] == "spctl" for command in completed))

    def test_missing_or_damaged_license_bundle_cannot_pass_release_verification(self):
        path = self.provider / notices.RESOURCE
        original = path.read_bytes()
        for invalid in (None, b"", original[:-1]):
            with self.subTest(invalid_size=None if invalid is None else len(invalid)):
                if invalid is None:
                    path.unlink()
                else:
                    path.write_bytes(invalid)
                with self.assertRaisesRegex(ReleaseError, "third-party notices"):
                    self.verify_with_inspections()
                path.write_bytes(original)

    def test_both_bundles_require_exact_nonempty_source_icon_bytes(self):
        changed = bytes([self.icon[0] ^ 1]) + self.icon[1:]
        for bundle in (self.app, self.provider):
            path = bundle / "Contents/Resources/MyDrive.icns"
            for invalid in (None, b"", changed):
                with self.subTest(bundle=bundle.name, invalid_size=None if invalid is None else len(invalid)):
                    if invalid is None:
                        path.unlink()
                    else:
                        path.write_bytes(invalid)
                    with self.assertRaisesRegex(ReleaseError, "app icon"):
                        self.verify_with_inspections()
                    path.write_bytes(self.icon)

    def test_both_bundles_require_the_exact_icon_plist_reference(self):
        for bundle in (self.app, self.provider):
            path = bundle / "Contents/Info.plist"
            original = path.read_bytes()
            for value in (None, "Other.icns", "../Resources/MyDrive.icns"):
                with self.subTest(bundle=bundle.name, value=value):
                    info = plistlib.loads(original)
                    if value is None:
                        del info["CFBundleIconFile"]
                    else:
                        info["CFBundleIconFile"] = value
                    path.write_bytes(plistlib.dumps(info))
                    with self.assertRaisesRegex(ReleaseError, "app icon metadata"):
                        self.verify_with_inspections()
                    path.write_bytes(original)

    def test_source_and_bundled_icons_refuse_symlinks_special_files_and_oversize(self):
        for path in (self.source_icon, self.app / "Contents/Resources/MyDrive.icns",
                     self.provider / "Contents/Resources/MyDrive.icns"):
            other = self.root / "owned-icon-copy"
            other.write_bytes(self.icon)
            for kind in ("symlink", "fifo", "oversize"):
                with self.subTest(path=path.parent.parent.name, kind=kind):
                    path.unlink()
                    if kind == "symlink":
                        path.symlink_to(other)
                    elif kind == "fifo":
                        os.mkfifo(path)
                    else:
                        with path.open("wb") as output:
                            output.truncate(release.MAX_ICON_BYTES + 1)
                    with self.assertRaisesRegex(ReleaseError, "app icon"):
                        self.verify_with_inspections()
                    path.unlink()
                    path.write_bytes(self.icon)

    def test_wrong_host_or_provider_team_is_rejected(self):
        for bundle in (self.app, self.provider):
            with self.subTest(bundle=bundle.name), self.assertRaisesRegex(ReleaseError, "configured Apple team"):
                self.verify_with_inspections(teams={bundle: "OTHER12345"})

    def test_provider_app_group_keychain_and_identity_cannot_drift(self):
        invalid = [
            ("com.apple.security.application-groups", ["group.somewhere.else"]),
            ("keychain-access-groups", ["ABC1234567.another.account"]),
            ("keychain-access-groups", [CONFIG["keychain_access_group"], "ABC1234567.extra"]),
            ("com.apple.application-identifier", CONFIG["team_id"] + ".another.provider"),
        ]
        for field, value in invalid:
            with self.subTest(field=field, value=value):
                entitlements = signed_entitlements(CONFIG["provider_bundle_id"])
                entitlements[field] = value
                with self.assertRaisesRegex(ReleaseError, "differs from configuration"):
                    self.verify_with_inspections(entitlements={self.provider: entitlements})

    def test_signing_key_file_size_and_permissions_are_checked(self):
        key = self.root / "dummy-key"
        key.write_bytes(b"x" * 1024)
        key.chmod(0o600)
        with patch.dict(os.environ, {"MYDRIVE_SPARKLE_KEY_FILE": str(key)}):
            self.assertEqual(release.signing_arguments(), ["--ed-key-file", str(key.resolve())])
            for size in (0, 1025):
                key.write_bytes(b"x" * size)
                with self.subTest(size=size), self.assertRaises(ReleaseError):
                    release.signing_arguments()
            key.write_bytes(b"dummy")
            key.chmod(0o640)
            with self.assertRaises(ReleaseError):
                release.signing_arguments()

    def test_oversized_key_cannot_reach_compiler_or_key_verifier(self):
        key = self.root / "oversized-dummy-key"
        key.write_bytes(b"x" * 1025)
        key.chmod(0o600)
        with patch.object(release, "ROOT", self.root), \
                patch.dict(os.environ, {"MYDRIVE_SPARKLE_KEY_FILE": str(key)}), \
                patch.object(release, "run") as commands, \
                patch.object(release.subprocess, "run") as subprocesses:
            with self.assertRaises(ReleaseError):
                release.verify_signing_key(self.root / "unused-sparkle", CONFIG)
            commands.assert_not_called()
            subprocesses.assert_not_called()

    def test_prepared_output_is_rejected_before_build_or_checks(self):
        final = self.root / "dist/releases/v0.2.0"
        final.mkdir(parents=True)
        retained = final / "original-artifact"
        retained.write_bytes(b"original prepared bytes")
        with patch.object(release, "ROOT", self.root), patch.object(release, "doctor") as doctor, \
                patch.object(release, "run") as commands:
            with self.assertRaisesRegex(ReleaseError, "already exists"):
                release.prepare(CONFIG, VERSION)
            doctor.assert_not_called()
            commands.assert_not_called()
        self.assertEqual(retained.read_bytes(), b"original prepared bytes")

    def test_prepare_packages_fresh_output_and_preserves_existing_dist_app(self):
        stale = self.root / "dist/MyDrive.app/Contents/MacOS/MyDrive"
        stale.parent.mkdir(parents=True)
        stale.write_bytes(b"stale previously built app")
        notes = self.root / "release/notes/0.2.0.md"
        notes.parent.mkdir(parents=True)
        notes.write_text("Release notes for the tested source.\n")
        fresh_bytes = b"fresh app from this release build"
        observed = {"build": None, "notary": None}

        def run(arguments, **kwargs):
            arguments = [str(value) for value in arguments]
            if arguments[0] == "bash" and arguments[1].endswith("/tools/check.sh"):
                return
            if arguments[0] == "bash" and arguments[1].endswith("/tools/build-macos.sh"):
                environment = kwargs["env"]
                output = Path(environment["MYDRIVE_DIST_DIR"])
                build = Path(environment["MYDRIVE_BUILD_DIR"])
                self.assertTrue(output.is_relative_to(self.root / ".build/release-work"))
                self.assertEqual(build.parent, output.parent)
                app = output / "MyDrive.app"
                executable = app / "Contents/MacOS/MyDrive"
                executable.parent.mkdir(parents=True)
                executable.write_bytes(fresh_bytes)
                info = {"CFBundleIdentifier": CONFIG["app_bundle_id"], "CFBundleVersion": VERSION["build"],
                        "CFBundleShortVersionString": VERSION["version"], "SUPublicEDKey": CONFIG["sparkle_public_key"],
                        "SUFeedURL": "https://github.com/example/MyDrive/releases/latest/download/appcast.xml",
                        "SURequireSignedFeed": True, "MyDriveDevelopmentBuild": False}
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                observed["build"] = app
                return
            if arguments[0] == "ditto":
                source, destination = Path(arguments[-2]), Path(arguments[-1])
                if "-x" in arguments:
                    with zipfile.ZipFile(source) as archive:
                        archive.extractall(destination)
                else:
                    with zipfile.ZipFile(destination, "w") as archive:
                        for file in source.rglob("*"):
                            if file.is_file():
                                archive.write(file, file.relative_to(source.parent))
                return
            if Path(arguments[0]).name == "generate_appcast":
                folder = Path(arguments[-1])
                archive = folder / "MyDrive-0.2.0-arm64.zip"
                prefix = "https://github.com/example/MyDrive/releases/download/v0.2.0/"
                signature = base64.b64encode(b"s" * 64).decode()
                (folder / "appcast.xml").write_text(f'''<rss xmlns:sparkle="{SPARKLE}"><channel><item>
<sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<sparkle:releaseNotesLink>{prefix}MyDrive-0.2.0-arm64.md</sparkle:releaseNotesLink>
<enclosure url="{prefix}{archive.name}" length="{archive.stat().st_size}" sparkle:edSignature="{signature}"/>
</item></channel></rss>''')
                return
            raise AssertionError("Unexpected external command: " + arguments[0])

        def notarize(app, folder, config):
            self.assertEqual((app / "Contents/MacOS/MyDrive").read_bytes(), fresh_bytes)
            observed["notary"] = app

        def verify_app(app, config):
            self.assertEqual((app / "Contents/MacOS/MyDrive").read_bytes(), fresh_bytes)

        # These adapters replace only external accounts/tools. The actual
        # prepare path still archives/extracts bytes and validates metadata,
        # appcast, hashes, immutable artifact membership and source identity.
        with patch.object(release, "ROOT", self.root), \
                patch.dict(os.environ, {"MYDRIVE_DIST_DIR": str(self.root / "wrong-output"),
                                        "MYDRIVE_BUILD_DIR": str(self.root / "wrong-build")}), \
                patch.object(release, "doctor", return_value=[]), \
                patch.object(release, "source_commit", return_value=COMMIT), \
                patch.object(release, "sparkle_path", return_value=self.root / "fake-sparkle"), \
                patch.object(release, "signing_arguments", return_value=["--account", "dummy"]), \
                patch.object(release, "verify_signing_key"), \
                patch.object(release, "verify_signatures"), \
                patch.object(release, "verify_app", side_effect=verify_app), \
                patch.object(release, "notarize", side_effect=notarize), \
                patch.object(release, "run", side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            release.prepare(CONFIG, VERSION)

        final = self.root / "dist/releases/v0.2.0"
        validate_manifest(final, CONFIG, VERSION, COMMIT)
        with zipfile.ZipFile(final / "MyDrive-0.2.0-arm64.zip") as archive:
            self.assertEqual(archive.read("MyDrive.app/Contents/MacOS/MyDrive"), fresh_bytes)
        self.assertEqual(observed["build"], observed["notary"])
        self.assertEqual(stale.read_bytes(), b"stale previously built app")
        self.assertFalse((self.root / "wrong-output").exists())


class LatestRelease(GitHub):
    """A read-only server adapter; any attempted publication fails the test."""
    def __init__(self, previous):
        super().__init__(CONFIG["repository"])
        self.previous = dict(previous, schema_version=MANIFEST_SCHEMA, repository=self.repository,
                             tag="v" + previous["version"], architecture="arm64", compatibility=release_compatibility(CONFIG))

    def api(self, path, *, method="GET", **kwargs):
        if method != "GET":
            raise AssertionError("Version rejection must precede server mutation")
        if path.endswith("/releases/latest"):
            return {"tag_name": "v" + self.previous["version"],
                    "assets": [{"id": 1, "name": "release-manifest.json"}]}
        if "/git/ref/tags/" in path:
            return {"ref": "refs/tags/" + path.rsplit("/", 1)[1], "object": {"type": "commit", "sha": COMMIT}}
        if path == "repos/" + self.repository:
            return {"private": False, "archived": False, "full_name": self.repository}
        raise AssertionError("Version rejection must precede draft/asset access")

    def asset_bytes(self, asset, destination):
        destination.write_text(json.dumps(self.previous))


class ReleaseOrderingTests(unittest.TestCase):
    def test_increased_build_cannot_publish_an_older_version(self):
        candidate = dict(repository=CONFIG["repository"], version="0.1.9", build="99",
                         tag="v0.1.9", commit=COMMIT, schema_version=MANIFEST_SCHEMA, compatibility=release_compatibility(CONFIG))
        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(ReleaseError, "both version and build"):
            LatestRelease({"version": "0.2.0", "build": "2"}).publish(Path(temporary), candidate, "Notes")

    def test_version_comparison_is_numeric_and_build_must_also_increase(self):
        github = LatestRelease({"version": "0.9.0", "build": "9"})
        candidate = dict(repository=CONFIG["repository"], version="0.10.0", build="10", tag="v0.10.0",
                         schema_version=MANIFEST_SCHEMA, compatibility=release_compatibility(CONFIG))
        github.check_newer(candidate)
        for changes in ({"version": "0.9.0"}, {"build": "9"}):
            with self.subTest(changes=changes), self.assertRaises(ReleaseError):
                github.check_newer(dict(candidate, **changes))


if __name__ == "__main__":
    unittest.main()
