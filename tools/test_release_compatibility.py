"""Update identity and final-publication races at the real publisher boundary."""
import base64
import copy
import json
from pathlib import Path
import tempfile
import unittest

from release_support import MANIFEST_SCHEMA, ReleaseError, release_compatibility, validate_manifest
from test_release import CONFIG, VERSION, FakeGitHub, fixture


class ChangingGitHub(FakeGitHub):
    def __init__(self, folder, manifest):
        super().__init__(folder, manifest)
        self.after_upload = None
        self.before_final_read = None
        self.release_reads = 0

    def upload(self, tag, path):
        super().upload(tag, path)
        if path.name == "appcast.xml" and self.after_upload:
            self.after_upload(self)

    def api(self, path, *, method="GET", **kwargs):
        if path.endswith("/releases/42") and method == "GET":
            self.release_reads += 1
            if self.release_reads == 2 and self.before_final_read:
                self.before_final_read(self)
        return super().api(path, method=method, **kwargs)


class ReleaseCompatibilityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mydrive-release-compatibility-")
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.manifest = fixture(self.folder)

    def latest(self, github, *, version="0.1.0", build="1"):
        previous = copy.deepcopy(self.manifest)
        previous.update(version=version, build=build, tag="v" + version)
        github.latest_manifest = previous
        github.latest = {"id": 10, "tag_name": previous["tag"], "assets": [
            {"id": 99, "name": "release-manifest.json"}]}
        return previous

    def test_first_signed_release_establishes_explicit_baseline_and_retry_reuses_it(self):
        github = ChangingGitHub(self.folder, self.manifest)
        self.assertEqual(self.manifest["schema_version"], MANIFEST_SCHEMA)
        self.assertEqual(self.manifest["compatibility"], release_compatibility(CONFIG))
        github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.publications, 1)
        self.latest(github, version=VERSION["version"], build=VERSION["build"])
        uploads = github.uploads[:]
        github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.uploads, uploads)
        self.assertEqual(github.publications, 1)

    def test_every_storage_signing_provider_and_update_identity_is_stable(self):
        changes = [
            {"app_bundle_id": "local.mydrive.other"},
            {"provider_bundle_id": "local.mydrive.other.provider"},
            {"app_group_id": "group.local.mydrive.other"},
            {"keychain_access_group": "ABC1234567.local.other"},
            {"sparkle_public_key": base64.b64encode(b"q" * 32).decode()},
            {"team_id": "XYZ9876543", "keychain_access_group": "XYZ9876543.local.mydrive"},
        ]
        for change in changes:
            github = ChangingGitHub(self.folder, self.manifest)
            self.latest(github)
            candidate = copy.deepcopy(self.manifest)
            candidate["compatibility"] = release_compatibility(dict(CONFIG, **change))
            with self.subTest(fields=tuple(change)), self.assertRaisesRegex(ReleaseError, "changes a published"):
                github.publish(self.folder, candidate, "Notes")
            self.assertIsNone(github.release)
            self.assertEqual(github.uploads, [])
            self.assertEqual(github.publications, 0)

    def test_missing_legacy_or_malformed_baseline_is_never_inferred(self):
        for mutation in (lambda m: m.pop("compatibility"), lambda m: m.update(schema_version=1),
                         lambda m: m["compatibility"].pop("app_group_id")):
            github = ChangingGitHub(self.folder, self.manifest)
            previous = self.latest(github)
            mutation(previous)
            with self.assertRaisesRegex(ReleaseError, "baseline"):
                github.publish(self.folder, self.manifest, "Notes")
            self.assertIsNone(github.release)
            self.assertEqual(github.uploads, [])
        first = copy.deepcopy(self.manifest)
        first.pop("compatibility")
        github = ChangingGitHub(self.folder, first)
        with self.assertRaisesRegex(ReleaseError, "baseline"):
            github.publish(self.folder, first, "Notes")
        self.assertIsNone(github.release)

    def test_local_artifact_manifest_cannot_claim_another_storage_baseline(self):
        changed = copy.deepcopy(self.manifest)
        changed["compatibility"]["app_group_id"] = "group.unrelated.storage"
        (self.folder / "release-manifest.json").write_text(json.dumps(changed))
        with self.assertRaisesRegex(ReleaseError, "source commit"):
            validate_manifest(self.folder, CONFIG, VERSION, "a" * 40)

    def test_final_draft_identity_and_channel_are_rechecked_before_patch(self):
        for field, value in (("tag_name", "v99.0.0"), ("prerelease", True), ("id", 43)):
            github = ChangingGitHub(self.folder, self.manifest)
            github.before_final_read = lambda server, f=field, v=value: server.release.update({f: v})
            with self.subTest(field=field), self.assertRaisesRegex(ReleaseError, "identity.*stable channel"):
                github.publish(self.folder, self.manifest, "Notes")
            self.assertTrue(github.release["draft"])
            self.assertEqual(github.publications, 0)

    def test_remote_tag_move_or_newer_public_release_during_upload_stops_publication(self):
        github = ChangingGitHub(self.folder, self.manifest)
        github.after_upload = lambda server: setattr(server, "target_sha", "b" * 40)
        with self.assertRaisesRegex(ReleaseError, "exact release commit"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.publications, 0)
        self.assertTrue(github.release["draft"])
        github = ChangingGitHub(self.folder, self.manifest)
        github.after_upload = lambda server: self.latest(server, version="0.3.0", build="3")
        with self.assertRaisesRegex(ReleaseError, "both version and build"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.publications, 0)
        self.assertTrue(github.release["draft"])

    def test_asset_replacement_after_hash_verification_stops_without_clobber(self):
        github = ChangingGitHub(self.folder, self.manifest)
        github.before_final_read = lambda server: server.release["assets"][0].update(id=12345, digest="sha256:" + "0" * 64)
        with self.assertRaisesRegex(ReleaseError, "assets changed"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.publications, 0)
        self.assertEqual(len(github.uploads), len(list(self.folder.iterdir())))


if __name__ == "__main__":
    unittest.main()
