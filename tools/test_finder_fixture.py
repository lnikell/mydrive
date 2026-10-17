#!/usr/bin/env python3
"""Local fixture deletion-boundary checks. The fake helper cannot contact a NAS."""
import copy
import hashlib
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import uuid

import finder_fixture as fixture
from test_nas_test_config import PUBLIC_TARGET


class FakeHelper:
    def __init__(self, spec, root):
        self.spec, self.root = spec, root
        self.target = dict(PUBLIC_TARGET)
        self.payload = {name: b"x" * (2 * 1024 * 1024) if name.endswith(".bin") else fixture.TEXT.encode()
                        for name in spec.files}
        self.directories = set(spec.directories)
        self.root_exists = True
        self.calls = []
        self.list_faults = {}
        self.corrupt = None

    def run(self, command, *arguments, expect_error=None):
        self.calls.append((command, *map(str, arguments)))
        if command == "list":
            path = arguments[0]
            if expect_error == "not_found":
                assert path == self.root and not self.root_exists
                return SimpleNamespace(complete=None, names=[])
            assert path == self.root or path.startswith(self.root + "/")
            directory = path[len(self.root):].lstrip("/")
            if directory and directory not in self.directories:
                raise fixture.BenchmarkError("missing fixture directory")
            names = sorted(name.rsplit("/", 1)[-1] for name in (*self.payload, *self.directories)
                           if name.rpartition("/")[0] == directory)
            result = {"complete": True, "entries": len(names)}
            fault = self.list_faults.get(directory)
            if fault:
                names, result = fault(names, result)
            return SimpleNamespace(complete={"result": result}, names=names)
        if command == "read":
            remote, destination = arguments
            assert remote.startswith(self.root + "/")
            name = remote[len(self.root) + 1:]
            payload = self.payload[name]
            if name == self.corrupt:
                payload = b"!" + payload[1:]
            with Path(destination).open("xb") as output:
                output.write(payload)
            return SimpleNamespace(complete={"result": {"bytes": len(payload)}})
        if command == "delete":
            name = arguments[0]
            if len(arguments) == 2:
                assert arguments[1] == "--directory" and name in self.directories
                assert not any(path.startswith(name + "/") for path in (*self.payload, *self.directories))
                self.directories.remove(name)
            else:
                assert name in self.payload
                del self.payload[name]
            return SimpleNamespace(complete={"result": {}})
        if command == "cleanup":
            assert not self.payload and not self.directories
            self.root_exists = False
            return SimpleNamespace(complete={"result": {}})
        raise AssertionError("fake helper rejects every unsupported command")


class FinderFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mydrive-finder-guards-")
        self.work = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def recorded(self, variant="nested"):
        spec = fixture.fixture(variant, self.work)
        root = ".mydrive-transport-tests/" + spec.prefix + uuid.uuid4().hex
        helper = FakeHelper(spec, root)
        report = {"target": dict(PUBLIC_TARGET), "remote_root": root, "status": "ready", "operations": [],
                  "files": {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                            for name, data in helper.payload.items()}}
        if variant != "basic":
            report["variant"] = variant
        return spec, report, helper

    def assertNoDeletion(self, helper):
        self.assertFalse(any(call[0] in ("delete", "cleanup") for call in helper.calls))

    def test_changed_or_unrecorded_nas_target_refuses_even_readback(self):
        for target in [None, dict(PUBLIC_TARGET, share="different-test-share")]:
            spec, report, helper = self.recorded()
            if target is None:
                del report["target"]
            else:
                report["target"] = target
            with self.assertRaises(fixture.BenchmarkError):
                fixture.verify_or_cleanup(helper, report, spec, lambda: None, cleanup=True)
            self.assertEqual(helper.calls, [])

    def test_basic_legacy_manifest_and_default_paths_remain_compatible(self):
        spec, report, helper = self.recorded("basic")
        fixture.verify_or_cleanup(helper, report, spec, lambda: None)
        self.assertNotIn("variant", report)
        self.assertEqual(report["status"], "ready")
        self.assertEqual(set(helper.payload), set(fixture.FILES))
        self.assertEqual(fixture.fixture().work, fixture.WORK)
        self.assertEqual(fixture.fixture().report_path, fixture.REPORT)
        self.assertEqual(fixture.fixture("nested").work.name, "finder-nested-fixture")
        self.assertNoDeletion(helper)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_nested_cleanup_verifies_every_file_before_known_nonrecursive_deletes(self):
        spec, report, helper = self.recorded()
        states = []
        fixture.verify_or_cleanup(helper, report, spec, lambda: states.append(report["status"]), cleanup=True)
        first_delete = next(index for index, call in enumerate(helper.calls) if call[0] == "delete")
        self.assertEqual(sum(call[0] == "read" for call in helper.calls[:first_delete]), len(spec.files))
        self.assertEqual([call[1:] for call in helper.calls if call[0] == "delete"],
                         [(name,) for name in spec.files] + [(name, "--directory") for name in reversed(spec.directories)])
        self.assertEqual(states, ["cleaning", "cleaned"])
        self.assertFalse(helper.root_exists)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_unknown_incomplete_missing_duplicate_and_malformed_directories_stop_deletion(self):
        deepest = "Offline folder/Nested one/Nested two"
        faults = [
            ("", lambda names, result: (names + ["unrelated.txt"], dict(result, entries=len(names) + 1))),
            (deepest, lambda names, result: (names + ["unrelated.txt"], dict(result, entries=len(names) + 1))),
            ("", lambda names, result: (names, dict(result, complete=False))),
            (deepest, lambda names, result: (names, dict(result, complete=False))),
            ("Offline folder", lambda names, result: (["Offline sample.bin"], dict(result, entries=1))),
            (deepest, lambda names, result: (names + names, dict(result, entries=len(names) * 2))),
            (deepest, lambda names, result: (["../unexpected"], dict(result, entries=1))),
            (deepest, lambda names, result: ([{"name": "Deep sample.bin"}], dict(result, entries=1))),
            (deepest, lambda names, result: (names, None)),
            (deepest, lambda names, result: (None, result)),
            (deepest, lambda names, result: (names, {"complete": True})),
        ]
        for directory, fault in faults:
            with self.subTest(directory=directory, fault=fault):
                spec, report, helper = self.recorded()
                helper.list_faults[directory] = fault
                with self.assertRaises(fixture.BenchmarkError):
                    fixture.verify_or_cleanup(helper, report, spec, lambda: None, cleanup=True)
                self.assertNoDeletion(helper)
                self.assertEqual(report["status"], "ready")
        spec, report, helper = self.recorded()
        helper.directories.remove(deepest)
        with self.assertRaises(fixture.BenchmarkError):
            fixture.verify_or_cleanup(helper, report, spec, lambda: None, cleanup=True)
        self.assertNoDeletion(helper)

    def test_last_file_hash_failure_retains_every_preflight_copy_and_all_remote_files(self):
        spec, report, helper = self.recorded()
        helper.corrupt = spec.files[-1]
        with self.assertRaisesRegex(fixture.BenchmarkError, "fixture changed"):
            fixture.verify_or_cleanup(helper, report, spec, lambda: None, cleanup=True)
        self.assertNoDeletion(helper)
        self.assertEqual(len(helper.payload), len(spec.files))
        self.assertEqual(len(list(self.work.glob("verify-*"))), len(spec.files))
        self.assertEqual(report["status"], "ready")

    def test_malformed_record_scope_status_and_metadata_fail_before_helper_calls(self):
        spec, good, _ = self.recorded()
        candidates = []
        for root in [good["remote_root"] + "/escape", ".mydrive-transport-tests/finder-nested-no-uuid",
                     ".mydrive-transport-tests/finder-nested-" + "0" * 32,
                     good["remote_root"].replace("finder-nested-", "finder-")]:
            altered = copy.deepcopy(good); altered["remote_root"] = root; candidates.append(altered)
        for field, value in [("status", "creating"), ("status", "cleaning"), ("status", None),
                             ("variant", "basic"), ("operations", {}), ("files", {})]:
            altered = copy.deepcopy(good); altered[field] = value; candidates.append(altered)
        malformed = copy.deepcopy(good); malformed["files"][spec.files[0]]["bytes"] = True
        candidates.append(malformed)
        malformed = copy.deepcopy(good); malformed["files"][spec.files[0]]["sha256"] = "invalid"
        candidates.append(malformed)
        candidates.extend([None, [], "not-a-report"])
        for report in candidates:
            with self.subTest(report=report):
                helper = FakeHelper(spec, good["remote_root"])
                with self.assertRaises(fixture.BenchmarkError):
                    fixture.verify_or_cleanup(helper, report, spec, lambda: None, cleanup=True)
                self.assertEqual(helper.calls, [])

    def test_helper_root_mismatch_and_uncertain_cleanup_cannot_be_replayed(self):
        spec, report, helper = self.recorded()
        helper.root += "/different"
        with self.assertRaises(fixture.BenchmarkError):
            fixture.verify_or_cleanup(helper, report, spec, lambda: None, cleanup=True)
        self.assertEqual(helper.calls, [])
        helper.root = report["remote_root"]
        def reject_persisting_cleanup_status():
            raise OSError("fake local persistence failure")
        with self.assertRaises(OSError):
            fixture.verify_or_cleanup(helper, report, spec, reject_persisting_cleanup_status, cleanup=True)
        self.assertNoDeletion(helper)
        self.assertEqual(report["status"], "cleaning")
        helper.calls.clear()
        with self.assertRaises(fixture.BenchmarkError):
            fixture.verify_or_cleanup(helper, report, spec, lambda: None, cleanup=True)
        self.assertEqual(helper.calls, [])


if __name__ == "__main__":
    unittest.main()
