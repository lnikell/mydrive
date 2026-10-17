"""Draft-first GitHub publication. Existing assets are verified, never clobbered."""
import json
from pathlib import Path
import re
import subprocess
import tempfile

from release_support import VERSION_RE, ReleaseError, digest, manifest_compatibility


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def api(self, path, *, method="GET", body=None, missing_ok=False):
        command = ["gh", "api", "--hostname", "github.com", path, "--method", method]
        if body is not None:
            command += ["--input", "-"]
        result = subprocess.run(command, input=json.dumps(body) if body is not None else None,
                                text=True, capture_output=True, timeout=120)
        if result.returncode:
            if missing_ok and "(HTTP 404)" in result.stderr:
                return None
            raise ReleaseError(f"GitHub API request failed for {path}. Check gh authentication and repository access.")
        return json.loads(result.stdout) if result.stdout.strip() else None

    def asset_bytes(self, asset, destination):
        # gh handles auth without placing a token in argv or source files.
        with destination.open("wb") as output:
            result = subprocess.run(["gh", "api", "--hostname", "github.com", f"repos/{self.repository}/releases/assets/{asset['id']}",
                                     "--header", "Accept: application/octet-stream"],
                                    stdout=output, stderr=subprocess.PIPE, timeout=300)
        if result.returncode:
            raise ReleaseError("Could not verify the uploaded release asset.")

    def verify_asset(self, asset, path):
        if asset.get("state") != "uploaded" or asset.get("size") != path.stat().st_size:
            raise ReleaseError(f"Release asset is incomplete: {path.name}. Inspect its release before retrying; retain the original prepared files. No asset was replaced.")
        expected = "sha256:" + digest(path)
        if asset.get("digest"):
            if asset["digest"] != expected:
                raise ReleaseError(f"Uploaded asset differs: {path.name}. It will not be overwritten.")
        else:
            with tempfile.TemporaryDirectory(prefix="mydrive-upload-check-") as temporary:
                downloaded = Path(temporary) / "asset"
                self.asset_bytes(asset, downloaded)
                if digest(downloaded) != digest(path):
                    raise ReleaseError(f"Uploaded asset differs: {path.name}. It will not be overwritten.")

    def upload(self, tag, path):
        result = subprocess.run(["gh", "release", "upload", tag, str(path), "--repo", "github.com/" + self.repository],
                                capture_output=True, timeout=300)
        if result.returncode:
            raise ReleaseError(f"Upload failed for {path.name}. Keep the draft and rerun publish to verify/resume.")

    def check_target(self, manifest):
        repo = self.api(f"repos/{self.repository}")
        if repo.get("private") is not False or repo.get("archived") is not False:
            raise ReleaseError("Public automatic updates require the intended public, active repository.")
        if not isinstance(repo.get("full_name"), str) or repo["full_name"].casefold() != self.repository.casefold():
            raise ReleaseError("The GitHub repository identity differs from release/config.json.")
        reference = self.api(f"repos/{self.repository}/git/ref/tags/{manifest['tag']}")
        if not isinstance(reference, dict) or reference.get("ref") != "refs/tags/" + manifest["tag"]:
            raise ReleaseError("Push the exact release tag to the configured repository first.")
        target = reference.get("object")
        seen = set()
        for _ in range(8):
            if not isinstance(target, dict) or not isinstance(target.get("sha"), str) \
                    or not re.fullmatch(r"[0-9a-f]{40}", target["sha"]):
                break
            if target.get("type") == "commit":
                if target["sha"] == manifest["commit"]:
                    return
                break
            if target.get("type") != "tag" or target["sha"] in seen:
                break
            seen.add(target["sha"])
            annotation = self.api(f"repos/{self.repository}/git/tags/{target['sha']}")
            target = annotation.get("object") if isinstance(annotation, dict) else None
        raise ReleaseError("Push the exact release commit and tag to the configured repository first.")

    def check_newer(self, manifest):
        compatibility = manifest_compatibility(manifest)
        latest = self.api(f"repos/{self.repository}/releases/latest", missing_ok=True)
        if latest is None:
            # The first verified signed archive establishes the explicit
            # compatibility contract. Later releases never infer a replacement.
            return
        assets = [x for x in latest["assets"] if x["name"] == "release-manifest.json"]
        if len(assets) != 1:
            raise ReleaseError("The existing latest release has no MyDrive manifest; reconcile the feed before publishing.")
        with tempfile.TemporaryDirectory(prefix="mydrive-latest-check-") as temporary:
            path = Path(temporary) / "manifest.json"
            self.asset_bytes(assets[0], path)
            if not 1 <= path.stat().st_size <= 65_536:
                raise ReleaseError("The published compatibility manifest exceeds its supported size.")
            previous = json.loads(path.read_text())
        if manifest_compatibility(previous) != compatibility:
            raise ReleaseError("The update changes a published signing, app/provider, storage, Keychain or Sparkle identity. Preserve the established compatibility baseline; qualify an explicit migration before releasing.")
        old_version = previous.get("version", "")
        if not isinstance(old_version, str) or not VERSION_RE.fullmatch(old_version):
            raise ReleaseError("The published latest release has an invalid version manifest.")
        if previous.get("repository") != manifest["repository"] or previous.get("tag") != latest["tag_name"] \
                or previous["tag"] != "v" + old_version or previous.get("architecture") != "arm64":
            raise ReleaseError("The published compatibility manifest does not identify the exact latest MyDrive release.")
        if latest["tag_name"] == manifest["tag"]:
            return
        if int(previous["build"]) >= int(manifest["build"]) \
                or tuple(map(int, old_version.split("."))) >= tuple(map(int, manifest["version"].split("."))):
            raise ReleaseError("A new release must increase both version and build over the published latest release.")

    @staticmethod
    def require_release_identity(release, manifest, expected_id=None):
        if not isinstance(release, dict) or type(release.get("id")) is not int or release["id"] <= 0 \
                or release.get("tag_name") != manifest["tag"] or release.get("prerelease") is not False \
                or type(release.get("draft")) is not bool \
                or (expected_id is not None and release["id"] != expected_id):
            raise ReleaseError("The release identity, exact tag or stable channel changed. Publication stopped; retain the prepared artifacts and inspect the draft.")

    @staticmethod
    def asset_snapshot(release):
        return sorted((asset["id"], asset["name"], asset.get("state"), asset.get("size"), asset.get("digest"))
                      for asset in release["assets"])

    def publish(self, folder, manifest, notes):
        self.check_target(manifest)
        self.check_newer(manifest)
        tag = manifest["tag"]
        path = f"repos/{self.repository}/releases"
        release = self.api(path + "/tags/" + tag, missing_ok=True)
        if release is None:
            release = self.api(path, method="POST", body={
                "tag_name": tag, "target_commitish": manifest["commit"],
                "name": f"MyDrive {manifest['version']}", "body": notes,
                "draft": True, "prerelease": False})
        self.require_release_identity(release, manifest)
        expected = {p.name: p for p in folder.iterdir()}
        assets = {x["name"]: x for x in release["assets"]}
        if set(assets) - set(expected):
            raise ReleaseError("The existing release contains unexpected assets. It will not be modified.")
        for name, asset in assets.items():
            self.verify_asset(asset, expected[name])
        missing = set(expected) - set(assets)
        if missing and not release["draft"]:
            raise ReleaseError("A public release is incomplete. Public releases are never changed by this script.")
        # appcast is uploaded after the archive/notes. Publication remains a
        # single final transition, so users never see a feed with absent assets.
        for name in sorted(missing, key=lambda n: (n == "appcast.xml", n)):
            self.upload(tag, expected[name])
        verified = self.api(f"{path}/{release['id']}")
        self.require_release_identity(verified, manifest, release["id"])
        if {x["name"] for x in verified["assets"]} != set(expected):
            raise ReleaseError("The draft asset set changed during publication. Publication stopped.")
        for asset in verified["assets"]:
            self.verify_asset(asset, expected[asset["name"]])
        if verified["draft"]:
            # Upload/hash verification can take minutes. Revalidate the remote
            # destination and ordering, then inspect this exact draft once more
            # before the only transition that can affect the stable feed.
            self.check_target(manifest)
            self.check_newer(manifest)
            final = self.api(f"{path}/{release['id']}")
            self.require_release_identity(final, manifest, release["id"])
            if self.asset_snapshot(final) != self.asset_snapshot(verified):
                raise ReleaseError("The draft assets changed after verification. Publication stopped; no asset was replaced.")
            if final["draft"]:
                published = self.api(f"{path}/{release['id']}", method="PATCH", body={"draft": False, "make_latest": "true"})
                self.require_release_identity(published, manifest, release["id"])
                if published["draft"]:
                    raise ReleaseError("GitHub did not confirm publication. Retain the prepared artifacts and inspect the release.")
        return f"https://github.com/{self.repository}/releases/tag/{tag}"
