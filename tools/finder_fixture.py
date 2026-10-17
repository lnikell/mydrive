#!/usr/bin/env python3
"""Create, verify, or clean one disposable fixture on the dedicated NAS share.

The default basic fixture preserves its original report and files. The nested
variant uses a separate report and fresh root to qualify unopened-folder pins.
"""
import argparse
from dataclasses import dataclass
import getpass
import json
from pathlib import Path
import re
import sys
import uuid

from nas_benchmark import BenchmarkError, Helper, PROJECT, file_hash, make_fixture, validate_target
from nas_test_config import load_nas_test_config

WORK = PROJECT / "Transport/.work/finder-fixture"
REPORT = WORK / "report.json"
FILES = ["Read me.txt", "Offline folder/Offline sample.bin", "Unicode — café.txt"]
TEXT = "MyDrive Finder verification\nThis file lives on the dedicated NAS test share.\n"
NESTED_DIRECTORIES = ("Offline folder", "Offline folder/Nested one", "Offline folder/Nested one/Nested two")
DEEP_FILE = "Offline folder/Nested one/Nested two/Deep sample.bin"


@dataclass(frozen=True)
class Fixture:
    variant: str
    work: Path
    prefix: str
    files: tuple
    directories: tuple

    @property
    def report_path(self):
        return self.work / "report.json"

    def membership(self, directory):
        return {path.rsplit("/", 1)[-1] for path in (*self.files, *self.directories)
                if path.rpartition("/")[0] == directory}


def fixture(variant="basic", work=None):
    if variant == "basic":
        return Fixture(variant, Path(work) if work is not None else WORK, "finder-", tuple(FILES), ("Offline folder",))
    if variant == "nested":
        return Fixture(variant, Path(work) if work is not None else PROJECT / "Transport/.work/finder-nested-fixture",
                       "finder-nested-", (*FILES, DEEP_FILE), NESTED_DIRECTORIES)
    raise BenchmarkError("unknown fixture variant")


def validate_report(report, spec):
    if not isinstance(report, dict):
        raise BenchmarkError("malformed fixture report")
    root = report.get("remote_root")
    prefix = ".mydrive-transport-tests/" + spec.prefix
    if not isinstance(root, str) or re.fullmatch(re.escape(prefix) + r"[0-9a-f]{32}", root) is None:
        raise BenchmarkError("invalid recorded fixture root")
    identity = uuid.UUID(hex=root[len(prefix):])
    if identity.version != 4 or identity.variant != uuid.RFC_4122:
        raise BenchmarkError("fixture root is not a generated UUID")
    files = report.get("files")
    if (report.get("status") != "ready" or report.get("variant", "basic") != spec.variant
            or not isinstance(files, dict) or set(files) != set(spec.files)
            or not isinstance(report.get("operations"), list)):
        raise BenchmarkError("fixture creation was incomplete or its manifest changed; inspect retained evidence")
    for name, metadata in files.items():
        expected_bytes = 2 * 1024 * 1024 if name.endswith(".bin") else len(TEXT.encode())
        if (not isinstance(metadata, dict) or type(metadata.get("bytes")) is not int
                or metadata["bytes"] != expected_bytes or not isinstance(metadata.get("sha256"), str)
                or re.fullmatch(r"[0-9a-f]{64}", metadata["sha256"]) is None):
            raise BenchmarkError("malformed fixture file metadata")
    return root


def verify_membership(helper, root, spec):
    for directory in ("", *spec.directories):
        remote = root + ("/" + directory if directory else "")
        observed = helper.run("list", remote)
        complete = observed.complete
        result = complete.get("result") if isinstance(complete, dict) else None
        names = observed.names
        expected = spec.membership(directory)
        if (not isinstance(result, dict) or result.get("complete") is not True
                or not isinstance(names, list) or not all(isinstance(name, str) for name in names)
                or type(result.get("entries")) is not int or result["entries"] != len(names)
                or len(names) != len(expected) or set(names) != expected):
            raise BenchmarkError("unexpected, incomplete, or malformed directory entries; refusing cleanup")


def verify_or_cleanup(helper, report, spec, save, *, cleanup=False):
    """The deletion boundary: every directory and every hash must pass first."""
    root = validate_report(report, spec)
    validate_target(report, helper.target)
    if helper.root != root:
        raise BenchmarkError("helper does not target the recorded fixture root")
    verify_membership(helper, root, spec)
    verified = []
    for name in spec.files:
        destination = spec.work / ("verify-" + uuid.uuid4().hex)
        received = helper.run("read", root + "/" + name, destination)
        result = received.complete.get("result", {})
        expected = report["files"][name]
        if (result.get("bytes") != expected["bytes"] or destination.stat().st_size != expected["bytes"]
                or file_hash(destination) != expected["sha256"]):
            raise BenchmarkError("fixture changed; retaining all remaining evidence")
        verified.append(destination)
    if cleanup:
        # A partial/uncertain cleanup must require inspection, not blind replay.
        report["status"] = "cleaning"
        save()
        for name in spec.files:
            helper.run("delete", name)
        for directory in reversed(spec.directories):
            helper.run("delete", directory, "--directory")
        helper.run("cleanup")
        helper.run("list", root, expect_error="not_found")
        report["status"] = "cleaned"
        save()
        for name in ("text.txt", "sample.bin"):
            (spec.work / name).unlink(missing_ok=True)
    for destination in verified:
        destination.unlink()


def run(mode, variant="basic"):
    target = load_nas_test_config()
    spec = fixture(variant)
    if mode == "create":
        if spec.report_path.exists():
            raise BenchmarkError("a recorded fixture exists; inspect and clean it first")
        spec.work.mkdir(parents=True, exist_ok=True)
        report = {"target": target, "remote_root": ".mydrive-transport-tests/" + spec.prefix + uuid.uuid4().hex,
                  "operations": [], "files": {}, "status": "creating"}
        if variant != "basic":
            report["variant"] = variant
    else:
        report = json.loads(spec.report_path.read_text())
        validate_report(report, spec)
        validate_target(report, target)
    password = getpass.getpass("Dedicated NAS test password: ").encode()
    if not (1 <= len(password) <= 4096):
        raise BenchmarkError("password must contain 1–4096 UTF-8 bytes")

    def save():
        temporary = spec.report_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(spec.report_path)

    root = report["remote_root"]
    helper = Helper(PROJECT / "Transport/target/release/nas-transport", password, root, report, save, 120, target=target)
    if mode == "create":
        helper.run("list", root, expect_error="not_found")
        text, sample = spec.work / "text.txt", spec.work / "sample.bin"
        text.write_text(TEXT)
        make_fixture(sample, 2 * 1024 * 1024)
        helper.run("prepare")
        for directory in spec.directories:
            helper.run("mkdir", directory)
        for name in spec.files:
            source = sample if name.endswith(".bin") else text
            helper.run("write", source, name)
            report["files"][name] = {"bytes": source.stat().st_size, "sha256": file_hash(source)}
            save()
        report["status"] = "ready"
        save()
        print("Finder fixture: " + root)
        print("Report: " + str(spec.report_path))
    else:
        verify_or_cleanup(helper, report, spec, save, cleanup=mode == "cleanup")
        print("Verified fixture removed; NAS originals outside this run are unchanged." if mode == "cleanup"
              else f"All {len(spec.files)} remote fixture hashes match; no remote data was changed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["create", "verify", "cleanup"])
    parser.add_argument("--variant", choices=["basic", "nested"], default="basic")
    args = parser.parse_args()
    try:
        run(args.mode, args.variant)
    except (BenchmarkError, OSError, ValueError, KeyError, TypeError) as error:
        print("Fixture operation stopped; evidence retained. " + str(error), file=sys.stderr)
        sys.exit(1)
