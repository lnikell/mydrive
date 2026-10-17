"""Recover the exact prepared release after a failed hosted publish job."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from release_github import GitHub
from release_support import ROOT, ReleaseError, source_commit, validate_manifest


def recover(config, version):
    tag = "v" + version["version"]
    commit = source_commit(tag)
    name = "mydrive-release-" + commit
    destination = ROOT / "dist/releases" / tag
    if destination.exists():
        validate_manifest(destination, config, version, commit)
        return True, name, destination
    github = GitHub(config["repository"])
    listing = github.api(f"repos/{config['repository']}/actions/artifacts?name={name}&per_page=100")
    candidates = [x for x in listing["artifacts"] if not x.get("expired") and x["name"] == name
                  and x.get("workflow_run", {}).get("head_sha") == commit]
    for artifact in candidates:
        workflow = github.api(f"repos/{config['repository']}/actions/runs/{artifact['workflow_run']['id']}")
        if workflow.get("path") != ".github/workflows/release.yml" or workflow.get("event") not in ("push", "workflow_dispatch"):
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="mydrive-recover-", dir=destination.parent) as temporary:
            stage = Path(temporary)
            result = subprocess.run(["gh", "run", "download", str(workflow["id"]), "--repo", config["repository"],
                                     "--name", name, "--dir", str(stage)], capture_output=True, timeout=300)
            if result.returncode:
                raise ReleaseError("Prepared CI artifact exists but could not be recovered. No replacement archive was built.")
            validate_manifest(stage, config, version, commit)
            shutil.copytree(stage, destination)
        return True, name, destination
    # A new notarized build has different bytes. Never regenerate over a partial
    # draft when the original CI artifact has expired or been deleted.
    draft = github.api(f"repos/{config['repository']}/releases/tags/{tag}", missing_ok=True)
    if draft and draft.get("assets"):
        raise ReleaseError("Release assets already exist, but their prepared CI artifact is unavailable. Recover the original artifacts before retrying.")
    return False, name, destination


def outputs(reused, name, folder):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as output:
            output.write(f"reused={'true' if reused else 'false'}\nartifact_name={name}\nfolder={folder}\n")
