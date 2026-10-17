#!/usr/bin/env python3
"""Reject local planning material and recognizable secrets before publication."""
import argparse
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

PRIVATE_DIRECTORIES = {".agents", ".codex", ".claude", ".build", ".runtime", ".local", "dist", "target",
                       ".cargo-home", ".work", ".signing", ".release-secrets", ".secrets", "secrets",
                       "planning", "plans", "research", "adr", "__pycache__", "xcuserdata"}
PRIVATE_SUFFIXES = {".p12", ".pfx", ".pem", ".key", ".p8", ".mobileprovision", ".provisionprofile",
                    ".keychain", ".keychain-db", ".keystore", ".jks", ".cer", ".crt", ".der"}
PUBLIC_MARKDOWN = {"README.md", "Core/README.md", "Transport/README.md", "docs/releasing.md"}
PUBLIC_CONFIG_KEYS = {"schema_version", "repository", "team_id", "keychain_access_group", "sparkle_public_key",
                      "app_bundle_id", "provider_bundle_id", "app_group_id"}
PRIVATE_DOCUMENT_STEMS = {"plan", "plans", "planning", "todo", "notes", "agents", "glossary"}
PRIVATE_KEY_NAMES = re.compile(r"(?:^|[-_.])(?:private[-_]?key|signing[-_]?key|update[-_]?key|api[-_]?key|credentials?|secrets?)(?:[-_.]|$)", re.I)
SECRET_JSON_FIELDS = {"password", "passwd", "token", "secret", "secret_key", "api_key", "apikey", "access_token",
                      "refresh_token", "client_secret", "private_key", "signing_key", "update_key", "certificate_password",
                      "mydrive_certificate_p12_base64", "mydrive_certificate_password", "mydrive_host_profile_base64",
                      "mydrive_provider_profile_base64", "mydrive_sparkle_private_key", "mydrive_notary_key_base64"}
SECRET_PATTERNS = [
    (re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"), "private key material"),
    (re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"), "GitHub token"),
    (re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"), "cloud access key"),
    (re.compile(rb"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@]+:[^\s/@]+@"), "credential-bearing URL"),
]


def contains_json_secret(value):
    if isinstance(value, dict):
        return any((str(key).lower() in SECRET_JSON_FIELDS and item not in (None, "", False))
                   or contains_json_secret(item) for key, item in value.items())
    return isinstance(value, list) and any(contains_json_secret(item) for item in value)


def findings(path, data):
    """Return only categories/line numbers; never return matched secret bytes."""
    file = PurePosixPath(path)
    lowered = {x.lower() for x in file.parts}
    result = []
    if lowered & PRIVATE_DIRECTORIES or file.name in {"AGENTS.md", "GLOSSARY.md"}:
        result.append((None, "local-only documents or generated/private data"))
    if file.name.lower().startswith("architecture-review-"):
        result.append((None, "private architecture review report"))
    if file.stem.lower() in PRIVATE_DOCUMENT_STEMS:
        result.append((None, "local-only planning or notes document"))
    if file.suffix.lower() in PRIVATE_SUFFIXES or file.name.lower().startswith((".env", "id_rsa", "id_ed25519")) \
            or PRIVATE_KEY_NAMES.search(file.name):
        result.append((None, "credential or signing file"))
    if file.parts[0] == "docs" and path != "docs/releasing.md":
        result.append((None, "private planning/research document"))
    is_notes = re.fullmatch(r"release/notes/[0-9]+\.[0-9]+\.[0-9]+\.md", path)
    if file.suffix.lower() == ".md" and path not in PUBLIC_MARKDOWN and not is_notes:
        result.append((None, "document outside the public documentation allowlist"))
    for pattern, category in SECRET_PATTERNS:
        for match in pattern.finditer(data):
            result.append((data[:match.start()].count(b"\n") + 1, category))
    if file.suffix.lower() == ".json":
        try:
            if contains_json_secret(json.loads(data)):
                result.append((None, "populated credential field in JSON"))
        except (ValueError, UnicodeDecodeError):
            pass
    if path == "release/config.json":
        try:
            config = json.loads(data)
            if not isinstance(config, dict) or set(config) != PUBLIC_CONFIG_KEYS:
                raise ValueError()
        except (ValueError, UnicodeDecodeError):
            result.append((None, "release configuration must contain only its documented public fields"))
    return result


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    if result.returncode:
        raise RuntimeError("Could not read the Git publication set.")
    return result.stdout


def check(root, working_tree=False):
    arguments = ["ls-files", "--cached", "-z"]
    if working_tree:
        arguments += ["--others", "--exclude-standard"]
    paths = sorted(set(x.decode("utf-8") for x in git(root, *arguments).split(b"\0") if x))
    problems = []
    for path in paths:
        file = root / path
        if working_tree:
            if not file.exists() and not file.is_symlink():
                continue
            if file.is_symlink():
                problems.append((path, None, "symbolic link requires explicit publication review"))
                continue
            data = file.read_bytes()
        else:
            mode = git(root, "ls-files", "--stage", "--", path).split(b" ", 1)[0]
            if mode != b"100644" and mode != b"100755":
                problems.append((path, None, "nonregular file requires explicit publication review"))
                continue
            # Inspect the actual index, even if a secret was edited out of the
            # working copy after staging it. gitignore never protects tracked data.
            data = git(root, "show", ":" + path)
        for line, category in findings(path, data):
            problems.append((path, line, category))
    return len(paths), problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--working-tree", action="store_true", help="Preview current tracked and unignored new files")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    count, problems = check(args.root, args.working_tree)
    for path, line, category in problems:
        location = path + (f":{line}" if line else "")
        print(f"{location}: {category}", file=sys.stderr)
    if problems:
        print("Publication stopped. Remove these files/values from the Git index; local files can stay ignored.", file=sys.stderr)
        return 1
    print(f"Publication check passed for {count} {'candidate' if args.working_tree else 'indexed'} files.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, UnicodeError) as error:
        print(f"Publication check stopped: {error}", file=sys.stderr)
        sys.exit(1)
