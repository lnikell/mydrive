import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from release_github import GitHub
from release_support import (SPARKLE, ReleaseError, artifact_records, configuration_problems,
                             digest, validate_manifest, version_info)


CONFIG = dict(schema_version=1, repository="example/MyDrive", team_id="ABC1234567",
              app_bundle_id="local.mydrive.app", provider_bundle_id="local.mydrive.app.provider",
              app_group_id="group.local.mydrive", keychain_access_group="ABC1234567.local.mydrive",
              sparkle_public_key=base64.b64encode(b"p" * 32).decode())
VERSION = {"version": "0.2.0", "build": "2"}


def fixture(folder):
    (folder / "MyDrive-0.2.0-arm64.zip").write_bytes(b"test archive bytes")
    (folder / "MyDrive-0.2.0-arm64.md").write_text("Release notes")
    (folder / "SHA256SUMS").write_text("test checksums")
    (folder / "appcast.xml").write_text(f'''<?xml version="1.0"?>
<rss xmlns:sparkle="{SPARKLE}"><channel><item>
<sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<sparkle:releaseNotesLink>https://github.com/example/MyDrive/releases/download/v0.2.0/MyDrive-0.2.0-arm64.md</sparkle:releaseNotesLink>
<enclosure url="https://github.com/example/MyDrive/releases/download/v0.2.0/MyDrive-0.2.0-arm64.zip"
 length="18" sparkle:edSignature="{base64.b64encode(b's' * 64).decode()}"/>
</item></channel></rss>''')
    manifest = dict(schema_version=1, repository=CONFIG["repository"], version="0.2.0", build="2",
                    tag="v0.2.0", commit="a" * 40, architecture="arm64", artifacts=artifact_records(folder))
    (folder / "release-manifest.json").write_text(json.dumps(manifest))
    return manifest


class FakeGitHub(GitHub):
    """Stateful fake at the actual GitHub interface, including failed uploads."""
    def __init__(self, folder, manifest):
        super().__init__(manifest["repository"])
        self.folder, self.manifest = folder, manifest
        self.release = None
        self.uploads = []
        self.publications = 0
        self.fail_upload = None
        self.target_sha = manifest["commit"]
        self.private = False
        self.latest = None
        self.full_name = self.repository
        self.tag_exists = True
        self.tag_object = None
        self.annotated = {}
        self.tag_reads = []

    def api(self, path, *, method="GET", body=None, missing_ok=False):
        prefix = "repos/" + self.repository
        if path == prefix:
            return {"private": self.private, "archived": False, "full_name": self.full_name}
        if path == prefix + "/commits/" + self.manifest["tag"]:
            # A same-named branch is deliberately still resolvable. Production
            # must request the exact tag reference rather than this endpoint.
            return {"sha": self.target_sha}
        if path == prefix + "/git/ref/tags/" + self.manifest["tag"]:
            if not self.tag_exists:
                return {}
            return {"ref": "refs/tags/" + self.manifest["tag"],
                    "object": self.tag_object or {"type": "commit", "sha": self.target_sha}}
        if path.startswith(prefix + "/git/tags/"):
            sha = path.rsplit("/", 1)[1]
            self.tag_reads.append(sha)
            return {"object": self.annotated.get(sha)}
        if path == prefix + "/releases/latest":
            return copy.deepcopy(self.latest)
        if method == "POST":
            self.release = dict(body, id=42, assets=[])
        elif method == "PATCH":
            self.release.update(body)
            self.publications += 1
        return copy.deepcopy(self.release)

    def upload(self, tag, path):
        self.uploads.append(path.name)
        if path.name == self.fail_upload:
            raise ReleaseError("Injected upload failure")
        self.release["assets"].append(dict(name=path.name, id=len(self.release["assets"]) + 1,
                                          state="uploaded", size=path.stat().st_size,
                                          digest="sha256:" + digest(path)))

    def asset_bytes(self, asset, destination):
        destination.write_bytes((self.folder / asset["name"]).read_bytes())


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.manifest = fixture(self.folder)

    def test_manifest_matches_source_and_detects_tampering(self):
        self.assertEqual(validate_manifest(self.folder, CONFIG, VERSION, "a" * 40), self.manifest)
        (self.folder / "MyDrive-0.2.0-arm64.zip").write_bytes(b"altered")
        with self.assertRaisesRegex(ReleaseError, "changed"):
            validate_manifest(self.folder, CONFIG, VERSION, "a" * 40)

    def test_wrong_commit_or_version_cannot_publish_prepared_bytes(self):
        with self.assertRaisesRegex(ReleaseError, "source commit"):
            validate_manifest(self.folder, CONFIG, VERSION, "b" * 40)
        with self.assertRaises(ReleaseError):
            validate_manifest(self.folder, CONFIG, {"version": "0.3.0", "build": "3"}, "a" * 40)

    def test_unexpected_assets_and_symlinks_are_rejected(self):
        (self.folder / "extra").write_text("not a release asset")
        with self.assertRaises(ReleaseError):
            validate_manifest(self.folder, CONFIG, VERSION, "a" * 40)
        (self.folder / "extra").unlink()
        (self.folder / "symlink").symlink_to(self.folder / "appcast.xml")
        with self.assertRaisesRegex(ReleaseError, "symlinks"):
            validate_manifest(self.folder, CONFIG, VERSION, "a" * 40)

    def test_config_requires_explicit_repository_team_and_key(self):
        self.assertEqual(configuration_problems(CONFIG), [])
        bad = dict(CONFIG, repository=None, team_id="guess", sparkle_public_key="not base64")
        self.assertEqual(len(configuration_problems(bad)), 3)

    def test_version_rejects_nonmonotonic_build_shapes(self):
        release = self.folder / "release"
        release.mkdir()
        for bad in ({"version": "v1.0.0", "build": "1"}, {"version": "1.0.0", "build": True},
                    {"version": "1.0.0", "build": "1.5"}, {"version": "1.0.0", "build": "0"}):
            (release / "version.json").write_text(json.dumps(bad))
            with self.assertRaises(ReleaseError):
                version_info(self.folder)

    def test_partial_upload_resumes_without_clobber_and_publishes_once(self):
        github = FakeGitHub(self.folder, self.manifest)
        github.fail_upload = "appcast.xml"
        with self.assertRaisesRegex(ReleaseError, "Injected"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertTrue(github.release["draft"])
        self.assertEqual(github.publications, 0)
        old_assets = copy.deepcopy(github.release["assets"])
        github.fail_upload = None
        github.publish(self.folder, self.manifest, "Notes")
        self.assertFalse(github.release["draft"])
        self.assertEqual(github.publications, 1)
        self.assertEqual(github.release["assets"][:len(old_assets)], old_assets)
        uploads = github.uploads[:]
        github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.uploads, uploads)
        self.assertEqual(github.publications, 1)
        self.assertEqual(uploads[-1], "appcast.xml")

    def test_corrupt_existing_asset_stops_before_any_upload_or_publish(self):
        github = FakeGitHub(self.folder, self.manifest)
        github.release = dict(id=42, draft=True, prerelease=False, assets=[dict(
            name="appcast.xml", state="uploaded", size=(self.folder / "appcast.xml").stat().st_size,
            digest="sha256:" + "0" * 64)])
        with self.assertRaisesRegex(ReleaseError, "differs"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.uploads, [])
        self.assertEqual(github.publications, 0)

    def test_public_incomplete_release_is_never_repaired_implicitly(self):
        github = FakeGitHub(self.folder, self.manifest)
        github.release = dict(id=42, draft=False, prerelease=False, assets=[])
        with self.assertRaisesRegex(ReleaseError, "never changed"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.uploads, [])

    def test_wrong_remote_tag_and_private_repo_stop_without_draft(self):
        github = FakeGitHub(self.folder, self.manifest)
        github.target_sha = "b" * 40
        with self.assertRaisesRegex(ReleaseError, "exact release commit"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertIsNone(github.release)
        github.target_sha = self.manifest["commit"]
        github.private = True
        with self.assertRaisesRegex(ReleaseError, "public"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertIsNone(github.release)

    def test_missing_server_digest_uses_downloaded_bytes(self):
        github = FakeGitHub(self.folder, self.manifest)
        archive = self.folder / "MyDrive-0.2.0-arm64.zip"
        github.verify_asset(dict(name=archive.name, id=1, state="uploaded", size=archive.stat().st_size), archive)

    def test_missing_remote_tag_cannot_be_replaced_by_same_named_branch(self):
        github = FakeGitHub(self.folder, self.manifest)
        github.tag_exists = False
        with self.assertRaisesRegex(ReleaseError, "exact release tag"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertIsNone(github.release)
        self.assertEqual(github.uploads, [])

    def test_annotated_tag_resolves_to_the_exact_intended_commit(self):
        github = FakeGitHub(self.folder, self.manifest)
        github.tag_object = {"type": "tag", "sha": "b" * 40}
        github.annotated["b" * 40] = {"type": "commit", "sha": self.manifest["commit"]}
        github.check_target(self.manifest)
        self.assertEqual(github.tag_reads, ["b" * 40])
        github.annotated["b" * 40] = {"type": "commit", "sha": "c" * 40}
        with self.assertRaisesRegex(ReleaseError, "exact release commit"):
            github.check_target(self.manifest)

    def test_cyclic_or_unsupported_tag_object_stops_before_publication(self):
        github = FakeGitHub(self.folder, self.manifest)
        github.tag_object = {"type": "tag", "sha": "b" * 40}
        github.annotated["b" * 40] = dict(github.tag_object)
        with self.assertRaises(ReleaseError):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.tag_reads, ["b" * 40])
        self.assertIsNone(github.release)
        github.tag_object = {"type": "tree", "sha": "b" * 40}
        with self.assertRaises(ReleaseError):
            github.check_target(self.manifest)

    def test_redirected_repository_identity_stops_before_publication(self):
        github = FakeGitHub(self.folder, self.manifest)
        github.full_name = "another-owner/MyDrive"
        with self.assertRaisesRegex(ReleaseError, "repository identity"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertIsNone(github.release)

    def test_all_cli_operations_pin_github_com_despite_host_override(self):
        commands = []
        def execute(arguments, **kwargs):
            commands.append(arguments)
            return subprocess.CompletedProcess(arguments, 0, stdout="{}", stderr="")
        github = GitHub(CONFIG["repository"])
        with patch.dict(os.environ, {"GH_HOST": "enterprise.example"}), \
                patch("release_github.subprocess.run", side_effect=execute):
            github.api("repos/" + CONFIG["repository"])
            github.asset_bytes({"id": 1}, self.folder / "download")
            github.upload("v0.2.0", self.folder / "MyDrive-0.2.0-arm64.zip")
        for command in commands[:2]:
            self.assertEqual(command[command.index("--hostname") + 1], "github.com")
        self.assertEqual(commands[2][commands[2].index("--repo") + 1], "github.com/" + CONFIG["repository"])

    def test_incomplete_starter_asset_stays_untouched_with_recovery_message(self):
        github = FakeGitHub(self.folder, self.manifest)
        github.release = dict(id=42, draft=True, prerelease=False, assets=[dict(
            name="appcast.xml", state="starter", size=0)])
        with self.assertRaisesRegex(ReleaseError, "Inspect its release.*original prepared"):
            github.publish(self.folder, self.manifest, "Notes")
        self.assertEqual(github.uploads, [])
        self.assertEqual(github.publications, 0)


if __name__ == "__main__":
    unittest.main()
