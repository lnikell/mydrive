#!/usr/bin/env python3
"""Guarded external-delete/restore trial for the recorded BASIC Finder fixture.

Only Read me.txt can be mutated. Finder observation/refresh happens separately
between modes. Passwords are prompted privately and piped to the native helper.
"""
import argparse
from dataclasses import replace
import fcntl
import getpass
import hashlib
import json
from pathlib import Path
import stat
import sys

from finder_fixture import BenchmarkError, Helper, PROJECT, fixture, validate_report, verify_or_cleanup
from nas_benchmark import file_hash, validate_target
from nas_test_config import load_nas_test_config

README = "Read me.txt"
STATE = PROJECT / ".runtime/finder-refresh-state.json"
STAGES = {"checking", "removing", "removed", "restoring", "restored"}


def manifest_digest(report):
    encoded = json.dumps(report["files"], sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def validate_state(state, root, report):
    if (not isinstance(state, dict) or type(state.get("version")) is not int or state["version"] != 1
            or state.get("remote_root") != root or state.get("manifest_sha256") != manifest_digest(report)
            or not isinstance(state.get("stage"), str) or state["stage"] not in STAGES
            or not isinstance(state.get("operations"), list)):
        raise BenchmarkError("refresh state does not match this ready basic fixture; inspect retained evidence")


def restore_source(spec, report):
    source = spec.work / "text.txt"
    expected = report["files"][README]
    info = source.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_size != expected["bytes"]
            or file_hash(source) != expected["sha256"]):
        raise BenchmarkError("original local Read me bytes are unavailable; refusing mutation")
    return source


def inspect(helper, report, spec, save, *, readme_present):
    # Reuse the same exhaustive membership/hash boundary as ordinary cleanup.
    # The survivor manifest differs only by the one deliberately missing file.
    observed_spec = spec if readme_present else replace(spec, files=tuple(name for name in spec.files if name != README))
    observed_report = report if readme_present else dict(
        report, files={name: report["files"][name] for name in observed_spec.files})
    verify_or_cleanup(helper, observed_report, observed_spec, save)


def readme_present(helper, root):
    # This chooses a canonical manifest; inspect() then requires complete exact
    # listings for every directory. An incomplete/malformed choice cannot pass.
    names = helper.run("list", root).names
    if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
        raise BenchmarkError("malformed fixture listing")
    return README in names


def exercise(mode, spec, report, state, helper, save):
    if mode not in ("remove-readme", "restore-readme") or spec.variant != "basic":
        raise BenchmarkError("this trial supports only the basic fixture")
    root = validate_report(report, spec)
    validate_state(state, root, report)
    validate_target(state, helper.target)
    if helper.root != root:
        raise BenchmarkError("helper does not target the recorded basic fixture")
    source = restore_source(spec, report)
    present = readme_present(helper, root)
    inspect(helper, report, spec, save, readme_present=present)
    if mode == "remove-readme":
        if not present:
            if state["stage"] not in ("removing", "removed"):
                raise BenchmarkError("Read me is already missing without a recorded deletion attempt")
            state["stage"] = "removed"
            save()
            return "Read me.txt is absent; verified survivors are intact. No deletion replayed."
        if state["stage"] in ("removed", "restoring"):
            raise BenchmarkError("Read me reappeared after deletion; use restore-readme to inspect it")
        state["stage"] = "removing"
        save()
        helper.run("delete", README)
        inspect(helper, report, spec, save, readme_present=False)
        state["stage"] = "removed"
        save()
        return "Removed only Read me.txt. Observe Finder, then refresh once before restoring."
    if present:
        state["stage"] = "restored"
        save()
        return "Original Read me.txt is already present; all three fixture hashes match. No write performed."
    state["stage"] = "restoring"
    save()
    # The native upload creates its destination exclusively, never replacing a
    # file that may have appeared since inspection. Unknown results stay staged.
    helper.run("write", source, README)
    inspect(helper, report, spec, save, readme_present=True)
    state["stage"] = "restored"
    save()
    return "Restored and read back the original 77-byte Read me.txt; all three fixture hashes match."


def run(mode):
    target = load_nas_test_config()
    spec = fixture("basic")
    report = json.loads(spec.report_path.read_text())
    root = validate_report(report, spec)
    validate_target(report, target)
    restore_source(spec, report)  # Establish recovery bytes before any NAS I/O.
    STATE.parent.mkdir(parents=True, exist_ok=True)
    with STATE.with_suffix(".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise BenchmarkError("another refresh-fixture operation is running") from error
        if STATE.exists():
            if STATE.stat().st_size > 256 * 1024:
                raise BenchmarkError("refresh state is oversized; inspect retained evidence")
            state = json.loads(STATE.read_text())
            validate_state(state, root, report)
        elif mode == "remove-readme":
            state = {"target": target, "version": 1, "remote_root": root, "manifest_sha256": manifest_digest(report),
                     "stage": "checking", "operations": []}
        else:
            raise BenchmarkError("restore requires the recorded refresh trial state")

        def save():
            temporary = STATE.with_suffix(".json.tmp")
            temporary.write_text(json.dumps(state, indent=2) + "\n")
            temporary.replace(STATE)

        validate_target(state, target)
        password = getpass.getpass("Dedicated NAS test password: ").encode()
        if not (1 <= len(password) <= 4096):
            raise BenchmarkError("password must contain 1–4096 UTF-8 bytes")
        save()
        helper = Helper(PROJECT / "Transport/target/release/nas-transport", password, root, state, save, 120, target=target)
        print(exercise(mode, spec, report, state, helper, save))
        print("Recovery state: " + str(STATE))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["remove-readme", "restore-readme"])
    args = parser.parse_args()
    try:
        run(args.mode)
    except (BenchmarkError, OSError, ValueError, KeyError, TypeError) as error:
        print("Refresh trial stopped; evidence/state retained. " + str(error), file=sys.stderr)
        sys.exit(1)
