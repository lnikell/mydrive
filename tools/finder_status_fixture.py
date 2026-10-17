#!/usr/bin/env python3
"""One fixed 512 MiB Finder-status fixture; never throttles or changes the app.

Create retains a single random file for Finder observation. Verify and cleanup
read its entire content independently of Finder. Mutations stay in a fresh UUID
root on the dedicated test share. Unknown/failed cleanup remains for inspection.
"""
import argparse
import fcntl
import getpass
import json
from pathlib import Path
import re
import shutil
import sys
import uuid

from finder_fixture import Fixture, verify_membership
from nas_benchmark import BenchmarkError, Helper, PROJECT, file_hash, make_fixture, validate_target
from nas_test_config import load_nas_test_config

WORK = PROJECT / "Transport/.work/finder-status-fixture"
NAME = "Progress sample.bin"
SIZE = 512 * 1024 * 1024
PREFIX = ".mydrive-transport-tests/finder-status-"
RESERVE = 256 * 1024 * 1024


def validate_report(report):
    if not isinstance(report, dict):
        raise BenchmarkError("malformed status-fixture report")
    root = report.get("remote_root")
    if not isinstance(root, str) or re.fullmatch(re.escape(PREFIX) + r"[0-9a-f]{32}", root) is None:
        raise BenchmarkError("invalid status-fixture root")
    identity = uuid.UUID(hex=root[len(PREFIX):])
    if identity.version != 4 or identity.variant != uuid.RFC_4122:
        raise BenchmarkError("status-fixture root is not a generated UUID")
    files = report.get("files")
    if (report.get("status") != "ready" or not isinstance(files, dict) or set(files) != {NAME}
            or not isinstance(report.get("operations"), list)):
        raise BenchmarkError("status fixture is incomplete or changed; inspect retained evidence")
    metadata = files[NAME]
    if (not isinstance(metadata, dict) or type(metadata.get("bytes")) is not int or metadata["bytes"] != SIZE
            or not isinstance(metadata.get("sha256"), str)
            or re.fullmatch(r"[0-9a-f]{64}", metadata["sha256"]) is None):
        raise BenchmarkError("malformed fixed-size status-fixture metadata")
    return root


def inspect(helper, report, work):
    root = validate_report(report)
    validate_target(report, helper.target)
    if helper.root != root:
        raise BenchmarkError("helper does not target the recorded status fixture")
    # Reuse canonical exact, exhaustive directory-membership verification.
    spec = Fixture("status", work, "finder-status-", (NAME,), ())
    verify_membership(helper, root, spec)
    if shutil.disk_usage(work).free < SIZE + RESERVE:
        raise BenchmarkError("not enough local space for verified readback and reserve")
    destination = work / ("verify-" + uuid.uuid4().hex)
    observed = helper.run("read", root + "/" + NAME, destination)
    result = observed.complete.get("result", {})
    if (result.get("bytes") != SIZE or destination.stat().st_size != SIZE
            or file_hash(destination) != report["files"][NAME]["sha256"]):
        raise BenchmarkError("status-fixture hash/size changed; retaining all evidence")
    return destination


def verify_or_cleanup(helper, report, work, save, *, cleanup=False):
    verified = inspect(helper, report, work)
    if cleanup:
        report["status"] = "cleaning"
        save()
        helper.run("delete", NAME)
        empty = Fixture("status", work, "finder-status-", (), ())
        verify_membership(helper, report["remote_root"], empty)
        helper.run("cleanup")
        helper.run("list", report["remote_root"], expect_error="not_found")
        report["status"] = "cleaned"
        save()
        (work / "source.bin").unlink(missing_ok=True)
    verified.unlink()


def run(mode):
    target = load_nas_test_config()
    WORK.mkdir(parents=True, exist_ok=True)
    with (WORK / "fixture.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise BenchmarkError("another status-fixture operation is running") from error
        report_path = WORK / "report.json"
        if mode == "create":
            if report_path.exists():
                raise BenchmarkError("a status-fixture report exists; inspect/clean it first")
            if shutil.disk_usage(WORK).free < 3 * SIZE + RESERVE:
                raise BenchmarkError("not enough local space for source, File Provider staging/cache, and reserve")
            report = {"target": target, "remote_root": PREFIX + uuid.uuid4().hex, "status": "creating", "files": {}, "operations": []}
        else:
            if report_path.stat().st_size > 256 * 1024:
                raise BenchmarkError("status-fixture report is oversized")
            report = json.loads(report_path.read_text())
            validate_report(report)
            validate_target(report, target)
        password = getpass.getpass("Dedicated NAS test password: ").encode()
        if not (1 <= len(password) <= 4096):
            raise BenchmarkError("password must contain 1–4096 UTF-8 bytes")

        def save():
            temporary = report_path.with_suffix(".json.tmp")
            temporary.write_text(json.dumps(report, indent=2) + "\n")
            temporary.replace(report_path)

        helper = Helper(PROJECT / "Transport/target/release/nas-transport", password,
                        report["remote_root"], report, save, 180, target=target)
        if mode == "create":
            save()
            helper.run("list", report["remote_root"], expect_error="not_found")
            source = WORK / "source.bin"
            digest = make_fixture(source, SIZE)  # Existing 1 MiB bounded stream generator.
            report["files"][NAME] = {"bytes": SIZE, "sha256": digest}
            save()
            helper.run("prepare")
            helper.run("write", source, NAME)
            spec = Fixture("status", WORK, "finder-status-", (NAME,), ())
            verify_membership(helper, report["remote_root"], spec)
            report["status"] = "ready"
            save()
            print("Created one 512 MiB fixture: " + report["remote_root"] + "/" + NAME)
            print("Expected SHA-256: " + digest)
        else:
            verify_or_cleanup(helper, report, WORK, save, cleanup=mode == "cleanup")
            print("Verified own file and removed only it plus its empty run directory." if mode == "cleanup"
                  else "Full remote status-fixture hash verified without accessing Finder's cached file.")
        print("Report: " + str(report_path))
        return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["create", "verify", "cleanup"])
    args = parser.parse_args()
    try:
        run(args.mode)
    except (BenchmarkError, OSError, ValueError, KeyError, TypeError) as error:
        print("Status fixture stopped; evidence retained. " + str(error), file=sys.stderr)
        sys.exit(1)
