#!/usr/bin/env python3
"""Fetch the pinned official Sparkle distribution, preserving framework links."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import urllib.request

VERSION = "2.10.0"
SHA256 = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SIZE = 16_319_840
URL = f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-{VERSION}.tar.xz"


def verify_archive(path):
    if path.stat().st_size != SIZE:
        raise ValueError("Sparkle archive length differs from the pinned release")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != SHA256:
        raise ValueError("Sparkle archive SHA-256 differs from the pinned release")


def extract_archive(archive, destination):
    with tarfile.open(archive, "r:xz") as source:
        members = source.getmembers()
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or member.isdev() or member.isfifo():
                raise ValueError("Unsafe Sparkle archive member")
            if member.issym() or member.islnk():
                target = (path.parent if member.issym() else PurePosixPath()) / member.linkname
                normalized = os.path.normpath(str(target))
                if target.is_absolute() or normalized == ".." or normalized.startswith("../"):
                    raise ValueError("Unsafe Sparkle archive link")
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError("Unsupported Sparkle archive member")
        source.extractall(destination, members=members)


def fetch(cache):
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / ".sparkle.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        archive = cache / f"Sparkle-{VERSION}.tar.xz"
        if not archive.exists():
            descriptor, temporary = tempfile.mkstemp(prefix="sparkle-download-", dir=cache)
            try:
                with os.fdopen(descriptor, "wb") as output, urllib.request.urlopen(URL, timeout=60) as response:
                    remaining = SIZE + 1
                    while remaining:
                        block = response.read(min(1024 * 1024, remaining))
                        if not block:
                            break
                        output.write(block)
                        remaining -= len(block)
                verify_archive(Path(temporary))
                os.replace(temporary, archive)
            finally:
                Path(temporary).unlink(missing_ok=True)
        verify_archive(archive)
        target = cache / f"Sparkle-{VERSION}"
        marker = target / ".mydrive-sparkle.json"
        expected = {"version": VERSION, "sha256": SHA256}
        if marker.exists() and json.loads(marker.read_text()) == expected and all(
                (target / relative).exists() for relative in
                ("Sparkle.framework/Sparkle", "bin/generate_appcast", "bin/sign_update", "bin/generate_keys")):
            return target
        temporary = Path(tempfile.mkdtemp(prefix="sparkle-extract-", dir=cache))
        try:
            extract_archive(archive, temporary)
            for relative in ("Sparkle.framework/Sparkle", "bin/generate_appcast", "bin/sign_update", "bin/generate_keys"):
                if not (temporary / relative).exists():
                    raise ValueError("Pinned Sparkle distribution is incomplete")
            (temporary / marker.name).write_text(json.dumps(expected) + "\n")
            if target.exists():
                shutil.rmtree(target)
            os.replace(temporary, target)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
        return target


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, default=Path(__file__).resolve().parents[1] / ".build/dependencies")
    arguments = parser.parse_args()
    try:
        print(fetch(arguments.cache_dir).resolve())
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"Sparkle fetch failed: {error}\n")
