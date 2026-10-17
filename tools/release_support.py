"""Release configuration and immutable artifact validation. No credentials in files."""
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_RE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


class ReleaseError(RuntimeError):
    pass


def run(args, *, cwd=ROOT, capture=False, input=None, env=None, timeout=1800):
    result = subprocess.run([str(x) for x in args], cwd=cwd, input=input,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None,
                            text=True, env=env, timeout=timeout)
    if result.returncode:
        # Arguments may contain paths to credentials, and tools can echo their
        # inputs. Keep failures useful without dumping secret-bearing commands.
        detail = result.stderr.strip() if capture and args[0] == "git" else ""
        raise ReleaseError(f"{Path(args[0]).name} failed (exit {result.returncode}). {detail}".strip())
    return result.stdout.strip() if capture else None


def version_info(root=ROOT):
    value = json.loads((root / "release/version.json").read_text())
    if not isinstance(value, dict):
        raise ReleaseError("release/version.json must contain an object.")
    version, build = value.get("version"), value.get("build")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        raise ReleaseError("release/version.json needs a stable major.minor.patch version.")
    if isinstance(build, bool) or not str(build).isascii() or not str(build).isdigit() or int(build) < 1:
        raise ReleaseError("The release build number must be a positive integer.")
    return {"version": version, "build": str(int(build))}


def release_config(root=ROOT):
    config = json.loads((root / "release/config.json").read_text())
    problems = _configuration_problems(config, allow_unconfigured=True)
    if problems:
        raise ReleaseError(" ".join(problems))
    return config


def configuration_problems(config):
    return _configuration_problems(config, allow_unconfigured=False)


def _configuration_problems(config, *, allow_unconfigured):
    """One set of public metadata rules for development builds and releases."""
    if not isinstance(config, dict) or type(config.get("schema_version")) is not int or config["schema_version"] != 1:
        return ["Unsupported release configuration schema."]
    problems = []
    identifier = r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"
    for field in ("app_bundle_id", "provider_bundle_id", "app_group_id"):
        value = config.get(field)
        if not isinstance(value, str) or not re.fullmatch(identifier, value):
            problems.append(f"Set a valid provisioned {field}.")
    if isinstance(config.get("app_group_id"), str) and not config["app_group_id"].startswith("group."):
        problems.append("app_group_id must use the registered group. prefix.")
    if config.get("app_bundle_id") == config.get("provider_bundle_id"):
        problems.append("The app and provider bundle identifiers must differ.")
    repository = config.get("repository")
    if not (allow_unconfigured and repository is None) and (not isinstance(repository, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", repository) or repository.split("/")[-1] in (".", "..")):
        problems.append("Set repository to the intended GitHub owner/name in release/config.json.")
    team = config.get("team_id")
    if not (allow_unconfigured and team is None) and (not isinstance(team, str) or not re.fullmatch(r"[A-Z0-9]{10}", team)):
        problems.append("Set the 10-character Apple Developer team_id.")
    group = config.get("keychain_access_group")
    if not (allow_unconfigured and group is None) and (not isinstance(group, str) or not re.fullmatch(identifier, group)):
        problems.append("Set the explicit provisioned keychain_access_group.")
    key = config.get("sparkle_public_key")
    if not (allow_unconfigured and key is None):
        try:
            if not isinstance(key, str) or len(base64.b64decode(key, validate=True)) != 32:
                raise ValueError()
        except (ValueError, TypeError):
            problems.append("Set sparkle_public_key to the public key from Sparkle generate_keys.")
    return problems


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def artifact_records(folder):
    return {p.name: {"sha256": digest(p), "size": p.stat().st_size}
            for p in sorted(folder.iterdir()) if p.is_file() and p.name != "release-manifest.json"}


def validate_manifest(folder, config, version, commit):
    manifest = json.loads((folder / "release-manifest.json").read_text())
    expected = {"schema_version": 1, "repository": config["repository"],
                "version": version["version"], "build": version["build"],
                "tag": "v" + version["version"], "commit": commit, "architecture": "arm64"}
    if any(manifest.get(k) != v for k, v in expected.items()):
        raise ReleaseError("Prepared artifacts do not match this repository, version, architecture and source commit.")
    records = manifest.get("artifacts")
    required = {f"MyDrive-{version['version']}-arm64.zip", "appcast.xml", "SHA256SUMS", f"MyDrive-{version['version']}-arm64.md"}
    if not isinstance(records, dict) or set(records) != required:
        raise ReleaseError("The release artifact set is incomplete or unexpected.")
    if any(p.is_symlink() or not p.is_file() for p in folder.iterdir()):
        raise ReleaseError("Release artifacts must be regular files, without symlinks or directories.")
    if artifact_records(folder) != records:
        raise ReleaseError("A release artifact was changed, added, or removed after preparation.")
    validate_appcast(folder / "appcast.xml", folder, config, version)
    return manifest


def validate_appcast(path, folder, config, version):
    root = ET.parse(path).getroot()
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ReleaseError("The stable appcast must contain exactly this release.")
    item = items[0]
    archive = folder / f"MyDrive-{version['version']}-arm64.zip"
    enclosure = item.find("enclosure")
    prefix = f"https://github.com/{config['repository']}/releases/download/v{version['version']}/"
    if enclosure is None or enclosure.get("url") != prefix + archive.name:
        raise ReleaseError("The appcast archive must use the immutable versioned GitHub asset URL.")
    if enclosure.get("length") != str(archive.stat().st_size):
        raise ReleaseError("The appcast archive length does not match.")
    for name, expected in (("version", version["build"]), ("shortVersionString", version["version"]),
                           ("hardwareRequirements", "arm64")):
        if item.findtext(f"{{{SPARKLE}}}{name}") != expected:
            raise ReleaseError(f"Incorrect appcast {name}.")
    try:
        if len(base64.b64decode(enclosure.get(f"{{{SPARKLE}}}edSignature", ""), validate=True)) != 64:
            raise ValueError()
    except ValueError:
        raise ReleaseError("The appcast is missing its EdDSA archive signature.") from None
    notes = item.find(f"{{{SPARKLE}}}releaseNotesLink")
    if notes is None or (notes.text or "").strip() != prefix + archive.with_suffix(".md").name:
        raise ReleaseError("The appcast release notes must use this release's asset URL.")


def source_commit(tag, root=ROOT):
    if run(["git", "status", "--porcelain"], cwd=root, capture=True):
        raise ReleaseError("Commit the intended source changes before preparing or publishing a release.")
    commit = run(["git", "rev-parse", "HEAD"], cwd=root, capture=True)
    tagged = run(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], cwd=root, capture=True)
    if tagged != commit:
        raise ReleaseError("Check out the exact release tag before preparing or publishing.")
    run(["python3", root / "tools/check-publication.py", "--root", root], cwd=root)
    return commit
