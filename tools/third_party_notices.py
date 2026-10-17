#!/usr/bin/env python3
"""Bundle complete upstream notices; MyDrive's MIT license does not replace them.

Cargo supplies the locked target-filtered graph, including build dependencies.
Only local files are read. This collects attribution texts, not legal advice.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TARGET = "aarch64-apple-darwin"
MAGIC = b"MyDrive third-party notices v1\n"
RESOURCE = "Contents/Resources/ThirdPartyLicenses.txt"
PROVIDER = "Contents/PlugIns/MyDriveProvider.appex"
MAX_FILE = 1024 * 1024
MAX_BUNDLE = 16 * 1024 * 1024
PREFIXES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "UNLICENSE")


class NoticesError(ValueError):
    pass


def safe_name(value):
    return isinstance(value, str) and 0 < len(value.encode("utf-8")) <= 4096 and not any(ord(c) < 32 for c in value)


def relative_file(root, value):
    if not safe_name(str(value)):
        raise NoticesError("Invalid notice file name.")
    path = Path(value)
    if ".." in path.parts:
        raise NoticesError("A notice file escapes its package.")
    if path.is_absolute():
        try:
            path = path.relative_to(root)
        except ValueError:
            raise NoticesError("A notice file escapes its package.") from None
    if not path.parts or path == Path("."):
        raise NoticesError("A notice file name is missing.")
    return path


def read_regular(root, relative, maximum=MAX_FILE):
    root = Path(root)
    path = relative_file(root, relative)
    current = root
    try:
        if not stat.S_ISDIR(current.lstat().st_mode):
            raise NoticesError("A notice directory is not an ordinary directory.")
        for part in path.parts[:-1]:
            current = current / part
            if not stat.S_ISDIR(current.lstat().st_mode):
                raise NoticesError("A notice directory is a symlink or special file.")
        descriptor = os.open(root / path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(descriptor, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum:
                raise NoticesError("A notice must be a nonempty, bounded regular file.")
            data = source.read(maximum + 1)
        if not 0 < len(data) <= maximum:
            raise NoticesError("A notice exceeds its size bound.")
        text = data.decode("utf-8")
        if not text.strip() or any(ord(c) < 32 and c not in "\n\r\t\f" for c in text):
            raise NoticesError("A notice is empty or binary instead of UTF-8 text.")
        return data
    except (OSError, UnicodeError):
        raise NoticesError("A required notice is missing, unsafe, or not UTF-8 text.") from None


def package_files(package):
    root = Path(package["manifest_path"]).parent
    if root.is_symlink():
        raise NoticesError("A package notice directory cannot be a symlink.")
    candidates = set()
    visited = 0
    def discovery_error(_error):
        raise NoticesError("Package notice discovery could not read a directory.")
    for directory, subdirectories, files in os.walk(root, followlinks=False, onerror=discovery_error):
        visited += len(subdirectories) + len(files)
        if visited > 50_000 or len(Path(directory).relative_to(root).parts) > 64:
            raise NoticesError("Package notice discovery exceeded its bound.")
        for name in subdirectories:
            if (Path(directory) / name).is_symlink():
                raise NoticesError("Package notice discovery encountered a symlink directory.")
        for name in files:
            if name.upper().startswith(PREFIXES):
                candidates.add((Path(directory) / name).relative_to(root))
    explicit = package.get("license_file")
    if explicit is not None:
        candidates.add(relative_file(root, explicit))
    if not candidates or len(candidates) > 256:
        raise NoticesError(f"Package {package['name']} has no complete local license text, or too many notice files.")
    return [(path.as_posix(), read_regular(root, path)) for path in sorted(candidates, key=lambda p: p.as_posix().encode("utf-8"))]


def dependencies(metadata):
    packages = {p["id"]: p for p in metadata["packages"]}
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    root = metadata["resolve"]["root"]
    if root not in packages or root not in nodes or len(packages) > 4096:
        raise NoticesError("Cargo did not provide a bounded resolved package root.")
    reached, pending = set(), [root]
    while pending:
        key = pending.pop()
        if key in reached:
            continue
        if key not in packages or key not in nodes:
            raise NoticesError("Cargo's resolved dependency graph is incomplete.")
        reached.add(key)
        for edge in nodes[key]["deps"]:
            kinds = edge.get("dep_kinds")
            if not kinds or any(k.get("kind") not in (None, "normal", "build", "dev") for k in kinds):
                raise NoticesError("Cargo returned an unsupported dependency kind.")
            if any(k.get("kind") != "dev" for k in kinds):
                pending.append(edge["pkg"])
    return [packages[key] for key in reached if key != root]


def cargo_metadata(root):
    environment = dict(os.environ, CARGO_HOME=str(root / "Transport/.cargo-home"))
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        try:
            result = subprocess.run(["cargo", "metadata", "--format-version", "1", "--locked", "--offline",
                                     "--filter-platform", TARGET], cwd=root / "Transport", env=environment,
                                    stdout=output, stderr=errors, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            raise NoticesError("Offline Cargo metadata could not be read.") from None
        if result.returncode or output.tell() > 8 * 1024 * 1024:
            raise NoticesError("Locked offline Cargo metadata is unavailable or exceeds its bound.")
        output.seek(0)
        return json.loads(output.read())


def render(components, version):
    body = bytearray()
    records = []
    for component in components:
        name, number, license_expression = (component[field] for field in ("name", "version", "license"))
        if not all(safe_name(value) for value in (name, number, license_expression)):
            raise NoticesError("A component has invalid public notice metadata.")
        body.extend(f"===== {name} {number} =====\nDeclared license: {license_expression}\n\n".encode())
        files = []
        for filename, data in component["files"]:
            relative_file(Path("."), filename)
            body.extend(f"----- {filename} -----\n".encode())
            files.append(dict(path=filename, offset=len(body), bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
            body.extend(data)
            body.extend(b"\n" if data.endswith(b"\n") else b"\n\n")
            if len(body) > MAX_BUNDLE:
                raise NoticesError("Combined third-party notices exceed their size bound.")
        records.append(dict(kind=component["kind"], name=name, version=number, license=license_expression, files=files))
    manifest = dict(schema_version=1, app_version=version, target=TARGET, components=records,
                    body_sha256=hashlib.sha256(body).hexdigest())
    data = MAGIC + json.dumps(manifest, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode() + b"\n\n" + body
    validate(data, version)
    return data


def generate(root, sparkle):
    from release_support import version_info
    version = version_info(root)["version"]
    metadata = cargo_metadata(root)
    cargo = []
    for package in dependencies(metadata):
        cargo.append(dict(kind="cargo", name=package["name"], version=package["version"],
                          license=package.get("license") or "See included texts", files=package_files(package)))
    cargo.sort(key=lambda c: (c["name"].encode(), c["version"].encode(), c["license"].encode(),
                             tuple((name.encode(), hashlib.sha256(data).digest()) for name, data in c["files"])))
    marker = json.loads(read_regular(sparkle, ".mydrive-sparkle.json"))
    if not isinstance(marker, dict) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", marker.get("version", "")):
        raise NoticesError("The pinned local Sparkle version is unavailable.")
    components = [dict(kind="project", name="MyDrive", version=version, license="MIT", files=[("LICENSE", read_regular(root, "LICENSE"))])]
    components += cargo
    components.append(dict(kind="sparkle", name="Sparkle", version=marker["version"],
                           license="See included LICENSE", files=[("LICENSE", read_regular(sparkle, "LICENSE"))]))
    return render(components, version)


def validate(data, version):
    if not data.startswith(MAGIC) or len(data) > MAX_BUNDLE:
        raise NoticesError("The bundled third-party notices are missing or invalid.")
    try:
        header, body = data[len(MAGIC):].split(b"\n\n", 1)
        if len(header) > 2 * 1024 * 1024:
            raise NoticesError("The notice manifest exceeds its bound.")
        value = json.loads(header)
        if (set(value) != {"schema_version", "app_version", "target", "components", "body_sha256"}
                or type(value["schema_version"]) is not int or value["schema_version"] != 1
                or value["app_version"] != version or value["target"] != TARGET
                or value["body_sha256"] != hashlib.sha256(body).hexdigest()):
            raise NoticesError("The bundled notice version, target or complete contents differ.")
        kinds, previous_end = [], 0
        if not 3 <= len(value["components"]) <= 4096:
            raise NoticesError("The bundled component notices are incomplete.")
        for component in value["components"]:
            if set(component) != {"kind", "name", "version", "license", "files"} or not 1 <= len(component["files"]) <= 256:
                raise NoticesError("A bundled component has no complete license text.")
            if not all(safe_name(component[k]) for k in ("name", "version", "license")):
                raise NoticesError("A bundled component has invalid metadata.")
            kinds.append(component["kind"])
            if component["kind"] == "project" and (component["name"], component["version"], component["license"]) != ("MyDrive", version, "MIT"):
                raise NoticesError("The MyDrive license/version notice is incorrect.")
            if component["kind"] == "sparkle" and (component["name"] != "Sparkle" or
                    not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", component["version"])):
                raise NoticesError("The Sparkle version/license notice is incorrect.")
            for file in component["files"]:
                if set(file) != {"path", "offset", "bytes", "sha256"}:
                    raise NoticesError("A bundled license record is incomplete.")
                relative_file(Path("."), file["path"])
                start, count = file["offset"], file["bytes"]
                if type(start) is not int or type(count) is not int or start < previous_end or not 0 < count <= MAX_FILE or start + count > len(body):
                    raise NoticesError("A bundled license text is missing or outside its bound.")
                text = body[start:start + count]
                if hashlib.sha256(text).hexdigest() != file["sha256"] or not text.decode("utf-8").strip() or b"\0" in text:
                    raise NoticesError("A bundled license text is incomplete or binary.")
                previous_end = start + count
        if kinds.count("project") != 1 or kinds.count("sparkle") != 1 or kinds.count("cargo") < 1 or set(kinds) != {"project", "sparkle", "cargo"}:
            raise NoticesError("The bundled MyDrive, Cargo or Sparkle notices are incomplete.")
        return value
    except (KeyError, TypeError, ValueError, UnicodeError) as error:
        if isinstance(error, NoticesError):
            raise
        raise NoticesError("The bundled third-party notice manifest is invalid.") from None


def verify_bundle(app, version):
    host = read_regular(app, RESOURCE, MAX_BUNDLE)
    provider = read_regular(app / PROVIDER, RESOURCE, MAX_BUNDLE)
    if host != provider:
        raise NoticesError("Host and provider third-party notices differ.")
    return validate(host, version)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--sparkle", type=Path, required=True)
    args = parser.parse_args()
    data = generate(ROOT, args.sparkle)
    for bundle in (args.app, args.app / PROVIDER):
        path = bundle / RESOURCE
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as output:
            output.write(data)
    print(f"Bundled complete third-party notices ({len(data)} bytes).")


if __name__ == "__main__":
    try:
        main()
    except (NoticesError, OSError, ValueError, KeyError) as error:
        print(f"Third-party notices stopped: {error}", file=sys.stderr)
        sys.exit(1)
