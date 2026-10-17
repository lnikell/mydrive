#!/usr/bin/env python3
"""Opt-in signed write trials in a fresh target-bound disposable NAS root."""
import copy
import getpass
import json
import re
from pathlib import Path
import sys
import uuid

from nas_benchmark import BenchmarkError, Helper, PROJECT, file_hash
from nas_test_config import load_nas_test_config


class MutationTrial:
    def __init__(self, helper, work, report, save):
        self.helper, self.work, self.report, self.save = helper, work, report, save
        self.files = {}
        self.directories = set()

    def stat(self, relative):
        return self.helper.run_request({"type": "stat", "path": self.path(relative)}).complete["result"]["entry"]

    def path(self, relative):
        if not relative or any(part in ("", ".", "..") for part in relative.split("/")) or "\\" in relative:
            raise BenchmarkError("invalid trial-relative path")
        return self.helper.root + "/" + relative

    def request(self, kind, relative, *, body=None, expected=None, destination=None):
        request = {"kind": kind, "path": self.path(relative), "operation_id": str(uuid.uuid4()),
                   "parent": self.parent_identity(self.path(relative))}
        if body is not None:
            source = self.work / (str(uuid.uuid4()) + ".payload")
            source.write_bytes(body)
            request["payload"] = {"source": str(source), "bytes": len(body), "sha256": file_hash(source)}
        if expected is not None:
            request["expected"] = expected
        if destination is not None:
            request["destination"] = self.path(destination)
            request["destination_parent"] = self.parent_identity(request["destination"])
        return request

    def parent_identity(self, path):
        parent = self.helper.run_request({"type": "stat", "path": path.rpartition("/")[0]}).complete["result"]["entry"]
        if not isinstance(parent, dict) or parent.get("directory") is not True:
            raise BenchmarkError("mutation parent is not an observed directory")
        identity = {key: parent.get(key) for key in ("index_number", "created_filetime")}
        if any(type(value) is not int or not 0 < value < 2 ** 64 for value in identity.values()):
            raise BenchmarkError("mutation parent lacks a safe identity")
        return identity

    def apply(self, request):
        # Each result's receipt is saved by Helper before its next request.
        # Never continue an unknown outcome or replace a receipt with a guess.
        request = copy.deepcopy(request)
        for _ in range(3):
            result = self.helper.run_request({"type": "mutate", "request": request}).complete["result"]
            if result.get("operation_id") != request["operation_id"]:
                raise BenchmarkError("mutation response belongs to a different operation")
            if result.get("outcome") == "committed":
                self.report["commits"].append(copy.deepcopy({"request": request, "result": result}))
                self.save()
                return result
            if (result.get("outcome") != "not_applied"
                    or result.get("code") not in ("allocated", "prepared")):
                raise BenchmarkError("mutation did not commit: " + str(result.get("code")))
            artifact = result.get("staged")
            entry = artifact.get("entry") if isinstance(artifact, dict) else None
            if (not isinstance(artifact, dict)
                    or artifact.get("phase", "prepared") != result["code"]
                    or (result["code"] == "allocated"
                        and (not isinstance(entry, dict)
                             or type(entry.get("bytes")) is not int or entry["bytes"] != 0
                             or re.fullmatch(r"[0-9a-f]{64}", str(artifact.get("security_sha256"))) is None))):
                raise BenchmarkError("mutation omitted its verified continuation receipt")
            request["receipt"] = {name: result[name] for name in ("staged", "archived") if result.get(name) is not None}
        raise BenchmarkError("mutation did not complete its bounded allocation/preparation continuation")

    def verify_bytes(self, relative, digest):
        destination = self.work / (str(uuid.uuid4()) + ".download")
        self.helper.run("read", self.path(relative), destination)
        if file_hash(destination) != digest:
            raise BenchmarkError("remote mutation SHA-256 did not match; retaining all evidence")
        self.files[relative] = digest
        self.report["files"] = dict(self.files)
        self.save()

    def cleanup_receipts(self, result):
        for name in ("staged", "archived"):
            artifact = result.get(name)
            if artifact is None:
                continue
            if artifact.get("cleanup_safe") is not True:
                raise BenchmarkError("original artifact requires inspection; no cleanup was attempted")
            request = {"kind": "cleanup", "operation_id": result["operation_id"],
                       "path": artifact["path"], "expected": artifact["entry"],
                       "parent": self.parent_identity(artifact["path"])}
            self.apply(request)

    def assert_membership(self):
        paths = set(self.files) | self.directories
        for directory in ("", *sorted(self.directories)):
            remote = self.helper.root + ("/" + directory if directory else "")
            listing = self.helper.run("list", remote)
            result = listing.complete["result"]
            names = listing.names
            if result.get("complete") is not True or type(result.get("entries")) is not int or result["entries"] != len(names):
                raise BenchmarkError("incomplete remote listing; retaining the trial")
            expected = {path.rsplit("/", 1)[-1] for path in paths if path.rpartition("/")[0] == directory}
            if len(names) != len(expected) or set(names) != expected:
                raise BenchmarkError("unexpected remote membership; retaining the trial")

    def run(self):
        self.helper.run("list", self.helper.root, expect_error="not_found")
        self.helper.run("prepare")
        self.assert_membership()
        folder = self.apply(self.request("create_directory", "folder"))
        self.directories.add("folder")
        name = "folder/Edited — café.txt"
        initial = self.request("create_file", name, body=b"original NAS bytes\n")
        created = self.apply(initial)
        self.verify_bytes(name, initial["payload"]["sha256"])
        # Replay the exact pre-publication receipt captured by apply, not an
        # identity reconstructed from the final pathname after the fact.
        replay = copy.deepcopy(self.report["commits"][-1]["request"])
        staged = replay.get("receipt", {}).get("staged")
        if not isinstance(staged, dict):
            raise BenchmarkError("create omitted its saved prepared receipt")
        observed = self.helper.run_request({"type": "reconcile", "request": replay}).complete["result"]
        expected_entry = created.get("entry")
        actual_entry = observed.get("entry")
        if (observed.get("operation_id") != initial["operation_id"] or observed.get("outcome") != "committed"
                or not isinstance(expected_entry, dict) or not isinstance(actual_entry, dict)
                or not isinstance(expected_entry.get("index_number"), int) or expected_entry["index_number"] <= 0
                or not isinstance(expected_entry.get("created_filetime"), int) or expected_entry["created_filetime"] <= 0
                or any(actual_entry.get(field) != expected_entry[field] for field in ("index_number", "created_filetime"))
                or observed.get("sha256") != initial["payload"]["sha256"]):
            raise BenchmarkError("committed create replay did not preserve verified identity and bytes")
        self.verify_bytes(name, initial["payload"]["sha256"])
        self.assert_membership()
        replacement = self.request("replace_file", name, body=b"saved replacement bytes\n", expected=self.stat(name))
        updated = self.apply(replacement)
        self.verify_bytes(name, replacement["payload"]["sha256"])
        self.cleanup_receipts(updated)
        # The same saved receipt becomes obsolete after a distinct replacement.
        observed = self.helper.run_request({"type": "reconcile", "request": replay}).complete["result"]
        if observed.get("operation_id") != initial["operation_id"] or observed.get("outcome") != "conflict":
            raise BenchmarkError("obsolete create replay failed to notice later replacement")
        # A stale base must preserve the newer NAS bytes and have no side effects.
        stale = self.request("replace_file", name, body=b"stale upload must not win\n", expected=created["entry"])
        refused = self.helper.run_request({"type": "mutate", "request": stale}).complete["result"]
        if refused.get("operation_id") != stale["operation_id"] or refused.get("outcome") != "conflict":
            raise BenchmarkError("stale base was not refused")
        self.verify_bytes(name, replacement["payload"]["sha256"])
        renamed = "folder/Renamed — cafe\u0301.txt"
        self.apply(self.request("move", name, destination=renamed, expected=self.stat(name)))
        digest = self.files.pop(name)
        self.verify_bytes(renamed, digest)
        case_changed = "folder/rENAMED — cafe\u0301.txt"
        self.apply(self.request("move", renamed, destination=case_changed, expected=self.stat(renamed)))
        self.files.pop(renamed)
        self.verify_bytes(case_changed, digest)
        renamed = "folder/rENAMED — café.txt"
        self.apply(self.request("move", case_changed, destination=renamed, expected=self.stat(case_changed)))
        self.files.pop(case_changed)
        self.verify_bytes(renamed, digest)
        self.assert_membership()
        # Verify all current bytes before the first intentional deletion.
        for path, digest in list(self.files.items()):
            self.verify_bytes(path, digest)
        deletion = self.apply(self.request("delete", renamed, expected=self.stat(renamed)))
        self.cleanup_receipts(deletion)
        self.files.pop(renamed)
        self.assert_membership()
        removal = self.apply(self.request("delete", "folder", expected=self.stat("folder")))
        self.cleanup_receipts(removal)
        self.directories.remove("folder")
        self.assert_membership()
        self.helper.run("cleanup")
        self.helper.run("list", self.helper.root, expect_error="not_found")
        self.report["files"] = dict(self.files)
        self.report["directories"] = sorted(self.directories)
        self.report["status"] = "passed"
        self.report["checks"] = ["staged receipt", "create", "committed replay identity", "obsolete replay conflict",
                                 "replace", "stale-base conflict", "rename", "case-only rename", "Unicode-only rename",
                                 "delete", "empty folder", "verified cleanup"]
        self.save()


def main():
    target = load_nas_test_config()
    run_id = uuid.uuid4().hex
    work = PROJECT / "Transport/.work/mutation-check" / run_id
    work.mkdir(parents=True)
    binary = PROJECT / "Transport/target/release/nas-transport"
    report = {"target": target, "remote_root": ".mydrive-transport-tests/mutations-" + run_id,
              "binary_sha256": file_hash(binary), "status": "running", "operations": [], "commits": [], "files": {}}
    report_path = work / "report.json"
    def save():
        temporary = report_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(report_path)
    save()
    password = getpass.getpass("Dedicated NAS test password: ").encode()
    if not 1 <= len(password) <= 4096:
        raise BenchmarkError("password must contain 1–4096 UTF-8 bytes")
    helper = Helper(binary, password, report["remote_root"], report, save,
                    120, target=target)
    try:
        MutationTrial(helper, work, report, save).run()
    except BaseException:
        report["status"] = "inspection_required"
        save()
        print("Trial stopped; generated files and evidence retained: " + str(report_path), file=sys.stderr)
        raise
    print("Signed mutation trial passed: " + str(report_path))


if __name__ == "__main__":
    try:
        main()
    except (BenchmarkError, OSError, ValueError, KeyError) as error:
        print("Mutation qualification stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
