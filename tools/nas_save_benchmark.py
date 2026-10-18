#!/usr/bin/env python3
"""Opt-in complete-save timing, using the production mutation state machine.

Only generated files in one fresh disposable test root can be changed. Independent
readback and cleanup happen after timing; internal save work remains included.
"""
import argparse
import datetime
import getpass
import json
import os
from pathlib import Path
import statistics
import sys
import time
import uuid
import warnings

from nas_benchmark import BenchmarkError, Helper, PROJECT, file_hash, make_fixture
from nas_mutation_check import ACKNOWLEDGED_SAVE_CONTRACT as CONTRACT, MutationTrial, confirmed_content
from nas_test_config import load_nas_test_config

def run_trial(trial, source, size, digest, index):
    name = f"payload-{index}.bin"
    expected = None
    timings = []
    for kind in ("create_file", "replace_file"):
        request = trial.request(kind, name, expected=expected)
        request["payload"] = {"source": str(source), "bytes": size, "sha256": digest}
        request["save_contract"] = CONTRACT
        first = len(trial.report["operations"])
        started = time.perf_counter()
        result = trial.apply(request)
        elapsed = time.perf_counter() - started
        if not confirmed_content(result, request["payload"], save_contract=CONTRACT):
            raise BenchmarkError("save did not return matching acknowledged-content evidence; retaining fixture")
        timings.append({"trial": index, "kind": kind, "wall_seconds": elapsed,
                        "MB_per_second": size / elapsed / 1_000_000,
                        "operation_indices": list(range(first, len(trial.report["operations"])))})
        trial.report["timings"].append(timings[-1])
        trial.save()
        trial.verify_bytes(name, digest)
        trial.cleanup_receipts(result)
        trial.assert_membership()
        expected = trial.stat(name)
    deletion = trial.apply(trial.request("delete", name, expected=expected))
    trial.cleanup_receipts(deletion)
    trial.files.pop(name)
    trial.assert_membership()
    return timings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm-test-share", action="store_true",
                        help="Confirm the configured share is dedicated to disposable tests")
    parser.add_argument("--bytes", type=int, default=256 * 1024 * 1024)
    parser.add_argument("--trials", type=int, default=3)
    args = parser.parse_args()
    if not args.confirm_test_share:
        parser.error("--confirm-test-share is required")
    if not 1 <= args.bytes <= 1024 ** 3 or not 1 <= args.trials <= 5:
        parser.error("Use 1–1073741824 bytes and 1–5 trials")
    if not sys.stdin.isatty():
        parser.error("Use an interactive terminal for hidden password entry")
    target = load_nas_test_config()
    binary = PROJECT / "Transport/target/release/nas-transport"
    nonce = uuid.uuid4().hex
    work = PROJECT / "Transport/.work/save-benchmarks" / nonce
    os.umask(0o077)
    work.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = {"status": "prepared_before_password", "target": target,
              "remote_root": ".mydrive-transport-tests/mutations-" + nonce,
              "binary_sha256": file_hash(binary), "save_contract": CONTRACT,
              "fixture_bytes": args.bytes, "trials": args.trials, "operations": [], "commits": [],
              "files": {}, "timings": [], "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "limits": ["Production helper save protocol; Finder/Swift are excluded, kernel/NAS contributions are not isolated.",
                         "Allocation, upload, flush, close and finalization are timed together.",
                         "Fixture generation, independent SHA readbacks and cleanup are outside timing.",
                         "Local/NAS caches and unrelated load are uncontrolled; MB uses decimal units."]}
    report_path = work / "report.json"

    def save():
        temporary = report_path.with_suffix(".tmp")
        with temporary.open("w") as stream:
            json.dump(report, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(report_path)

    source = work / "source.bin"
    make_fixture(source, args.bytes)
    digest = file_hash(source)
    report["fixture_sha256"] = digest
    save()
    warnings.simplefilter("error", getpass.GetPassWarning)
    password = getpass.getpass("Dedicated NAS test password (hidden): ").encode()
    if not 1 <= len(password) <= 4096:
        raise BenchmarkError("password length invalid")
    helper = Helper(binary, password, report["remote_root"], report, save, 180, target=target)
    trial = MutationTrial(helper, work, report, save, save_contract=CONTRACT)
    try:
        helper.run("list", helper.root, expect_error="not_found")
        helper.run("prepare")
        trial.assert_membership()
        for index in range(1, args.trials + 1):
            run_trial(trial, source, args.bytes, digest, index)
        helper.run("cleanup")
        helper.run("list", helper.root, expect_error="not_found")
        report["status"] = "passed"
        report["medians_MB_per_second"] = {kind: statistics.median(
            row["MB_per_second"] for row in report["timings"] if row["kind"] == kind)
            for kind in ("create_file", "replace_file")}
    except BaseException as error:
        report["status"] = "failed_retained"
        report["failure"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        del password
        report["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        save()
        print("Report: " + str(report_path), flush=True)
    for kind, value in report["medians_MB_per_second"].items():
        print(f"{kind}: {value:.2f} MB/s median complete save")


if __name__ == "__main__":
    try:
        main()
    except (BenchmarkError, OSError, ValueError, KeyboardInterrupt) as error:
        print("Save benchmark stopped; evidence retained: " + str(error), file=sys.stderr)
        sys.exit(1)
