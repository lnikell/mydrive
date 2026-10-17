"""Local release setup: persisted nonsecret paths and read-only prerequisites."""
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess

from macos_build import signing_identity
from release_support import ROOT, ReleaseError

PATH_FIELDS = frozenset(("MYDRIVE_HOST_PROFILE", "MYDRIVE_PROVIDER_PROFILE",
                         "MYDRIVE_NOTARY_KEY_PATH", "MYDRIVE_SPARKLE_KEY_FILE"))
LOCAL_FIELDS = PATH_FIELDS | frozenset(("MYDRIVE_SIGN_IDENTITY", "MYDRIVE_NOTARY_KEYCHAIN_PROFILE",
                                       "MYDRIVE_NOTARY_KEY_ID", "MYDRIVE_NOTARY_ISSUER_ID"))


def _unique_fields(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ReleaseError("Local release settings contain duplicate fields.")
        value[key] = item
    return value


def release_environment(root=ROOT, environment=None):
    """Read only an allowlisted JSON map; explicit process values take priority."""
    environment = dict(os.environ if environment is None else environment)
    source = root / ".local/release.json"
    try:
        descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return _normalized_paths(root, environment)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ReleaseError("Local release settings must be a regular JSON file.")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = None
            data = stream.read(16_385)
        if len(data) > 16_384:
            raise ReleaseError("Local release settings exceed their size limit.")
        try:
            settings = json.loads(data, object_pairs_hook=_unique_fields)
        except (ValueError, UnicodeError):
            raise ReleaseError("Local release settings must be valid UTF-8 JSON.") from None
        if not isinstance(settings, dict) or set(settings) - LOCAL_FIELDS:
            raise ReleaseError("Local release settings accept only documented path, identity and profile variables; no passwords, tokens or raw keys.")
        for name, value in settings.items():
            if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > 4096 \
                    or any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise ReleaseError("Local release values must be nonblank bounded strings without control characters.")
            if name not in environment:
                environment[name] = value
        return _normalized_paths(root, environment)
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _normalized_paths(root, environment):
    for name in PATH_FIELDS:
        value = environment.get(name)
        if value:
            path = Path(value).expanduser()
            environment[name] = str((path if path.is_absolute() else root / path).resolve())
    return environment


def _quiet(arguments):
    """Never expose tool output, including authentication status and failures."""
    try:
        return subprocess.run(arguments, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
        return None


def prerequisite_problems(root=ROOT, environment=None):
    environment = os.environ if environment is None else environment
    problems = []
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        problems.append("This release channel requires an Apple silicon Mac (arm64).")
    available = {name: shutil.which(name) for name in ("git", "xcrun", "codesign", "ditto", "cargo", "gh", "security")}
    problems.extend(f"Install {name} before releasing." for name, path in available.items() if not path)
    if not (root / ".git").exists():
        problems.append("Initialize Git and configure the intended GitHub origin.")
    if available["xcrun"]:
        for tool in ("swiftc", "notarytool", "stapler"):
            result = _quiet(["xcrun", "--find", tool])
            if result is None or result.returncode:
                problems.append(f"Select developer tools containing {tool}.")
        compiler = _quiet(["xcrun", "swiftc", "--version"])
        version = re.search(r"Swift version ([0-9]+)\.([0-9]+)", compiler.stdout) if compiler and not compiler.returncode else None
        if not version or tuple(map(int, version.groups())) < (6, 2):
            problems.append("Select Swift 6.2 or later; Xcode/Command Line Tools 26.2 is the tested toolchain.")
    if available["gh"]:
        result = _quiet(["gh", "auth", "status", "--active", "--hostname", "github.com"])
        if result is None or result.returncode:
            problems.append("GitHub CLI did not confirm active github.com authentication. Run gh auth login and check connectivity.")
    identity = environment.get("MYDRIVE_SIGN_IDENTITY")
    if not identity or identity == "-":
        problems.append("Set MYDRIVE_SIGN_IDENTITY to a Developer ID Application signing identity.")
    elif available["security"]:
        identities = _quiet(["security", "find-identity", "-v", "-p", "codesigning"])
        try:
            signing_identity(identity, identities.stdout if identities and not identities.returncode else "")
        except ValueError:
            problems.append("The configured Developer ID Application identity with its private key is not available in the local signing Keychain.")
    for name in ("MYDRIVE_HOST_PROFILE", "MYDRIVE_PROVIDER_PROFILE"):
        if not Path(environment.get(name, "/nonexistent")).expanduser().is_file():
            problems.append(f"Set {name} to its Developer ID provisioning profile.")
    if not environment.get("MYDRIVE_NOTARY_KEYCHAIN_PROFILE"):
        names = ("MYDRIVE_NOTARY_KEY_PATH", "MYDRIVE_NOTARY_KEY_ID", "MYDRIVE_NOTARY_ISSUER_ID")
        if not all(environment.get(name) for name in names):
            problems.append("Configure a notarytool Keychain profile or App Store Connect API key paths and identifiers.")
        elif not Path(environment["MYDRIVE_NOTARY_KEY_PATH"]).expanduser().is_file():
            problems.append("MYDRIVE_NOTARY_KEY_PATH must name an existing App Store Connect key file.")
    key = environment.get("MYDRIVE_SPARKLE_KEY_FILE")
    if key:
        path = Path(key).expanduser()
        if not path.is_file() or path.stat().st_mode & 0o077 or not 1 <= path.stat().st_size <= 1024:
            problems.append("MYDRIVE_SPARKLE_KEY_FILE must name an existing private key file (mode 0600).")
    # Stored notary profiles and the default Sparkle Keychain account are not
    # queried here. Preparation verifies access and actual matching keys.
    return problems
