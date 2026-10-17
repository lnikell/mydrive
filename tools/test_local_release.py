"""Local settings/preflight and ship recovery; no accounts, signing or network."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import local_release
import release
from release_support import ReleaseError
from test_release import CONFIG, VERSION, fixture


class LocalSettingsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / ".local").mkdir()
        self.path = self.root / ".local/release.json"

    def test_missing_local_settings_do_not_change_process_environment(self):
        environment = {"EXISTING": "untouched"}
        result = local_release.release_environment(self.root, environment)
        self.assertEqual(result, environment)
        self.assertIsNot(result, environment)

    def test_allowed_metadata_resolves_paths_and_process_values_win(self):
        self.path.write_text(json.dumps({"MYDRIVE_HOST_PROFILE": "./signing/host.provisionprofile",
                                         "MYDRIVE_NOTARY_KEYCHAIN_PROFILE": "local-notary",
                                         "MYDRIVE_SIGN_IDENTITY": "Developer ID Application: Example"}))
        explicit = {"MYDRIVE_SIGN_IDENTITY": "explicit identity", "MYDRIVE_NOTARY_KEYCHAIN_PROFILE": ""}
        result = local_release.release_environment(self.root, explicit)
        self.assertEqual(result["MYDRIVE_SIGN_IDENTITY"], explicit["MYDRIVE_SIGN_IDENTITY"])
        self.assertEqual(result["MYDRIVE_NOTARY_KEYCHAIN_PROFILE"], "")
        self.assertEqual(result["MYDRIVE_HOST_PROFILE"], str((self.root / "signing/host.provisionprofile").resolve()))
        self.assertEqual(explicit, {"MYDRIVE_SIGN_IDENTITY": "explicit identity", "MYDRIVE_NOTARY_KEYCHAIN_PROFILE": ""})

    def test_explicit_path_overrides_are_normalized_even_without_local_settings(self):
        environment = {"MYDRIVE_SPARKLE_KEY_FILE": "~/synthetic-key", "MYDRIVE_HOST_PROFILE": "./profile"}
        result = local_release.release_environment(self.root, environment)
        self.assertEqual(result["MYDRIVE_SPARKLE_KEY_FILE"], str(Path("~/synthetic-key").expanduser().resolve()))
        self.assertEqual(result["MYDRIVE_HOST_PROFILE"], str((self.root / "profile").resolve()))
        self.assertEqual(environment["MYDRIVE_HOST_PROFILE"], "./profile")

    def test_unknown_secret_and_control_fields_fail_without_echoing_values(self):
        secret = "synthetic-do-not-echo"
        invalid = [{"GH_TOKEN": secret}, {"MYDRIVE_SPARKLE_PRIVATE_KEY": secret}, {"password": secret},
                   {"MYDRIVE_HOST_PROFILE": secret + "\n"}, {"MYDRIVE_HOST_PROFILE": 42},
                   {"MYDRIVE_HOST_PROFILE": " "}, {"MYDRIVE_HOST_PROFILE": "x" * 4097}, []]
        for settings in invalid:
            self.path.write_text(json.dumps(settings))
            with self.assertRaises(ReleaseError) as error:
                local_release.release_environment(self.root, {})
            self.assertNotIn(secret, str(error.exception))

    def test_duplicate_oversized_symlink_and_nonregular_settings_fail_closed(self):
        for data in (b'{"MYDRIVE_SIGN_IDENTITY":"a","MYDRIVE_SIGN_IDENTITY":"b"}', b" " * 16385):
            self.path.write_bytes(data)
            with self.assertRaises(ReleaseError):
                local_release.release_environment(self.root, {})
        self.path.unlink()
        self.path.symlink_to(self.root / "missing")
        with self.assertRaises(OSError):
            local_release.release_environment(self.root, {})
        self.path.unlink()
        self.path.mkdir()
        with self.assertRaises(ReleaseError):
            local_release.release_environment(self.root, {})


class LocalDoctorTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / ".git").mkdir()
        self.profile = self.root / "host.provisionprofile"
        self.profile.write_bytes(b"synthetic profile metadata")
        self.environment = {"MYDRIVE_SIGN_IDENTITY": "Developer ID Application: Example",
                            "MYDRIVE_HOST_PROFILE": str(self.profile), "MYDRIVE_PROVIDER_PROFILE": str(self.profile),
                            "MYDRIVE_NOTARY_KEYCHAIN_PROFILE": "local-notary"}

    def fake_command(self, arguments, **kwargs):
        self.assertTrue(kwargs["capture_output"])
        self.assertEqual(kwargs["timeout"], 20)
        if arguments[:2] == ["gh", "auth"]:
            self.assertEqual(arguments, ["gh", "auth", "status", "--active", "--hostname", "github.com"])
            return subprocess.CompletedProcess(arguments, 0, stdout="synthetic auth detail", stderr="")
        if arguments[:2] == ["security", "find-identity"]:
            return subprocess.CompletedProcess(arguments, 0, stdout='A' * 40 + ' "Developer ID Application: Example"', stderr="")
        if "--version" in arguments:
            return subprocess.CompletedProcess(arguments, 0, stdout="Apple Swift version 6.2.3", stderr="")
        return subprocess.CompletedProcess(arguments, 0, stdout="/selected/tool", stderr="")

    def test_preflight_uses_only_read_only_metadata_and_does_not_query_secrets(self):
        output = io.StringIO()
        with patch.object(local_release.platform, "system", return_value="Darwin"), \
                patch.object(local_release.platform, "machine", return_value="arm64"), \
                patch.object(local_release.shutil, "which", side_effect=lambda name: "/tools/" + name), \
                patch.object(local_release.subprocess, "run", side_effect=self.fake_command) as commands, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertEqual(local_release.prerequisite_problems(self.root, self.environment), [])
        self.assertEqual(output.getvalue(), "")
        self.assertEqual([call.args[0] for call in commands.call_args_list if call.args[0][0] == "security"],
                         [["security", "find-identity", "-v", "-p", "codesigning"]])

    def test_failed_or_timed_out_authentication_never_echoes_output_or_arguments(self):
        failures = [subprocess.CompletedProcess([], 1, stdout="synthetic-secret", stderr="synthetic-secret"),
                    subprocess.TimeoutExpired(["gh", "synthetic-secret"], 20, output="synthetic-secret")]
        for result in failures:
            def command(arguments, **kwargs):
                if arguments[0] == "gh":
                    if isinstance(result, Exception):
                        raise result
                    return result
                return self.fake_command(arguments, **kwargs)
            with patch.object(local_release.platform, "system", return_value="Darwin"), \
                    patch.object(local_release.platform, "machine", return_value="arm64"), \
                    patch.object(local_release.shutil, "which", side_effect=lambda name: name), \
                    patch.object(local_release.subprocess, "run", side_effect=command):
                issues = local_release.prerequisite_problems(self.root, self.environment)
            self.assertTrue(any("gh auth login" in issue for issue in issues))
            self.assertNotIn("synthetic-secret", str(issues))


class ShipTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        notes = self.root / "release/notes"
        notes.mkdir(parents=True)
        (notes / "0.2.0.md").write_text("Local release notes")
        self.folder = self.root / "dist/releases/v0.2.0"
        self.publisher = type("FakePublisher", (), {})()
        self.calls = []
        self.remote = None
        self.publisher.check_target = lambda manifest: self.calls.append("remote-target")
        self.publisher.check_newer = lambda manifest: self.calls.append("remote-version")
        self.publisher.api = lambda *args, **kwargs: self.remote
        self.publisher.publish = lambda *args: self.calls.append("publish") or "https://github.com/example/MyDrive/releases/tag/v0.2.0"
        for name, value in [("ROOT", self.root), ("source_commit", lambda tag: "a" * 40),
                            ("GitHub", lambda repository: self.publisher),
                            ("validate_origin", lambda *args: self.calls.append("origin")),
                            ("sparkle_path", lambda: self.root / "tools"),
                            ("verify_signatures", lambda *args: self.calls.append("signatures")),
                            ("check_archive", lambda *args: self.calls.append("archive"))]:
            patcher = patch.object(release, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def make_prepared(self):
        self.folder.mkdir(parents=True)
        return fixture(self.folder)

    def test_first_ship_prepares_once_then_fully_verifies_before_publication(self):
        def prepare(*args):
            self.calls.append("prepare")
            self.make_prepared()
        with patch.object(release, "prepare", side_effect=prepare):
            release.ship(CONFIG, VERSION)
        self.assertEqual(self.calls, ["origin", "remote-target", "remote-version", "prepare", "origin", "signatures", "archive", "publish"])

    def test_retained_signed_bytes_are_reused_on_every_retry(self):
        self.make_prepared()
        before = {path.name: path.read_bytes() for path in self.folder.iterdir()}
        with patch.object(release, "prepare") as prepare, contextlib.redirect_stdout(io.StringIO()):
            release.ship(CONFIG, VERSION)
            release.ship(CONFIG, VERSION)
        prepare.assert_not_called()
        self.assertEqual({path.name: path.read_bytes() for path in self.folder.iterdir()}, before)
        self.assertEqual(self.calls.count("publish"), 2)

    def test_remote_assets_or_public_release_without_originals_never_rebuild(self):
        for remote in ({"draft": True, "assets": [{"name": "appcast.xml"}]}, {"draft": False, "assets": []}):
            self.remote = remote
            with patch.object(release, "prepare") as prepare, self.assertRaisesRegex(ReleaseError, "original local artifacts"):
                release.ship(CONFIG, VERSION)
            prepare.assert_not_called()
        self.assertNotIn("publish", self.calls)

    def test_corrupt_originals_or_failed_signature_cannot_trigger_rebuild_or_publish(self):
        self.make_prepared()
        archive = self.folder / "MyDrive-0.2.0-arm64.zip"
        archive.write_bytes(b"altered")
        with patch.object(release, "prepare") as prepare, self.assertRaises(ReleaseError):
            release.ship(CONFIG, VERSION)
        prepare.assert_not_called()
        self.assertNotIn("publish", self.calls)
        fixture(self.folder)
        with patch.object(release, "verify_signatures", side_effect=ReleaseError("Invalid signature")), \
                patch.object(release, "prepare") as prepare, self.assertRaisesRegex(ReleaseError, "Invalid signature"):
            release.ship(CONFIG, VERSION)
        prepare.assert_not_called()
        self.assertNotIn("publish", self.calls)

    def test_unpushed_tag_or_wrong_origin_stops_before_building(self):
        for name in ("validate_origin", "source_commit"):
            with patch.object(release, name, side_effect=ReleaseError("Invalid source target")), \
                    patch.object(release, "prepare") as prepare, self.assertRaises(ReleaseError):
                release.ship(CONFIG, VERSION)
            prepare.assert_not_called()
        self.assertNotIn("publish", self.calls)

    def test_remote_tag_validation_precedes_first_prepare(self):
        self.publisher.check_target = lambda manifest: (_ for _ in ()).throw(ReleaseError("Push the exact tag first"))
        with patch.object(release, "prepare") as prepare, self.assertRaisesRegex(ReleaseError, "exact tag"):
            release.ship(CONFIG, VERSION)
        prepare.assert_not_called()
        self.assertFalse(self.folder.exists())

    def test_direct_publish_checks_origin_and_offline_verify_does_not(self):
        self.make_prepared()
        with patch.object(release, "validate_origin", side_effect=ReleaseError("Wrong origin")), self.assertRaisesRegex(ReleaseError, "Wrong origin"):
            release.publish_prepared(CONFIG, VERSION)
        self.assertNotIn("publish", self.calls)
        with patch.object(release, "validate_origin", side_effect=AssertionError("Offline verification must not inspect origin")):
            release.verified_release(CONFIG, VERSION)

    def test_obsolete_version_or_existing_prerelease_stops_before_preparation(self):
        self.publisher.check_newer = lambda manifest: (_ for _ in ()).throw(ReleaseError("Version must increase"))
        with patch.object(release, "prepare") as prepare, self.assertRaisesRegex(ReleaseError, "increase"):
            release.ship(CONFIG, VERSION)
        prepare.assert_not_called()
        self.publisher.check_newer = lambda manifest: None
        self.remote = {"draft": True, "assets": [], "prerelease": True}
        with patch.object(release, "prepare") as prepare, self.assertRaisesRegex(ReleaseError, "prerelease"):
            release.ship(CONFIG, VERSION)
        prepare.assert_not_called()
