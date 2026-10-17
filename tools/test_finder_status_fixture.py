#!/usr/bin/env python3
"""Local-only guards for the fixed-size status fixture; fake helper has no I/O transport."""
import contextlib
import copy
import hashlib
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

import finder_status_fixture as fixture
from test_nas_test_config import PUBLIC_TARGET


class Remote:
    def __init__(self):
        self.exists = False
        self.data = None
        self.extra = False
        self.complete = True
        self.corrupt = False
        self.calls = []

    def helper(self, binary, password, root, report, save, timeout, *, target=PUBLIC_TARGET):
        owner = self
        class FakeHelper:
            def __init__(self):
                self.root = root
                self.target = dict(target)
            def run(self, command, *arguments, expect_error=None):
                owner.calls.append((command, *map(str, arguments)))
                if command == "list":
                    assert arguments == (root,)
                    if expect_error == "not_found":
                        if owner.exists:
                            raise fixture.BenchmarkError("root already exists")
                        return SimpleNamespace(complete=None, names=[])
                    if not owner.exists:
                        raise fixture.BenchmarkError("root missing")
                    names = ([fixture.NAME] if owner.data is not None else []) + (["unrelated.txt"] if owner.extra else [])
                    return SimpleNamespace(names=names, complete={"result": {
                        "complete": owner.complete, "entries": len(names)}})
                if command == "prepare":
                    assert not owner.exists
                    owner.exists = True
                elif command == "write":
                    source, name = arguments
                    assert name == fixture.NAME and owner.data is None
                    owner.data = Path(source).read_bytes()
                elif command == "read":
                    remote, destination = arguments
                    assert remote == root + "/" + fixture.NAME
                    payload = owner.data if not owner.corrupt else b"!" + owner.data[1:]
                    with Path(destination).open("xb") as output:
                        output.write(payload)
                    return SimpleNamespace(complete={"result": {"bytes": len(payload)}})
                elif command == "delete":
                    assert arguments == (fixture.NAME,) and not owner.extra
                    owner.data = None
                elif command == "cleanup":
                    assert owner.data is None and not owner.extra
                    owner.exists = False
                else:
                    raise AssertionError("fake helper rejects unsupported operations")
                return SimpleNamespace(complete={"result": {}})
        return FakeHelper()


class FinderStatusFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mydrive-status-guards-")
        self.work = Path(self.temporary.name)
        self.remote = Remote()
        self.stack = contextlib.ExitStack()
        self.stack.enter_context(patch.object(fixture, "WORK", self.work))
        self.stack.enter_context(patch.object(fixture, "SIZE", 32768))  # Unit-only bounded data; CLI has no size option.
        self.stack.enter_context(patch.object(fixture, "Helper", self.remote.helper))
        self.stack.enter_context(patch.object(fixture, "load_nas_test_config", return_value=dict(PUBLIC_TARGET)))
        self.stack.enter_context(patch.object(fixture.getpass, "getpass", return_value="dummy-not-a-real-password"))
        self.stack.enter_context(patch.object(fixture.shutil, "disk_usage", return_value=SimpleNamespace(free=2**30)))
        self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))

    def tearDown(self):
        self.stack.close()
        self.temporary.cleanup()

    def create(self):
        return fixture.run("create")

    def helper(self, report):
        return self.remote.helper(None, b"dummy", report["remote_root"], report, lambda: None, 1)

    def mutations(self):
        return [call for call in self.remote.calls if call[0] in ("delete", "cleanup")]

    def test_changed_target_report_blocks_all_additional_helper_calls(self):
        report = self.create()
        baseline = len(self.remote.calls)
        report["target"]["share"] = "different-test-share"
        with self.assertRaises(fixture.BenchmarkError):
            fixture.verify_or_cleanup(self.helper(report), report, self.work, lambda: None, cleanup=True)
        self.assertEqual(len(self.remote.calls), baseline)

    def test_create_verify_cleanup_roundtrip_removes_only_verified_literal_file_and_empty_root(self):
        report = self.create()
        self.assertEqual(set(report["files"]), {fixture.NAME})
        self.assertEqual(hashlib.sha256(self.remote.data).hexdigest(), report["files"][fixture.NAME]["sha256"])
        fixture.run("verify")
        fixture.run("cleanup")
        self.assertFalse(self.remote.exists)
        self.assertEqual(self.mutations(), [("delete", fixture.NAME), ("cleanup",)])
        deletion = next(index for index, call in enumerate(self.remote.calls) if call[0] == "delete")
        self.assertEqual(sum(call[0] == "read" for call in self.remote.calls[:deletion]), 2)
        self.assertFalse((self.work / "source.bin").exists())
        self.assertEqual(list(self.work.glob("verify-*")), [])
        self.assertNotIn("dummy-not-a-real-password", (self.work / "report.json").read_text())

    def test_unknown_or_incomplete_membership_refuses_cleanup(self):
        report = self.create()
        self.remote.extra = True
        with self.assertRaises(fixture.BenchmarkError):
            fixture.verify_or_cleanup(self.helper(report), report, self.work, lambda: None, cleanup=True)
        self.remote.extra = False
        self.remote.complete = False
        with self.assertRaises(fixture.BenchmarkError):
            fixture.verify_or_cleanup(self.helper(report), report, self.work, lambda: None, cleanup=True)
        self.assertEqual(self.mutations(), [])
        self.assertEqual(report["status"], "ready")

    def test_changed_payload_retains_remote_and_readback_evidence(self):
        report = self.create()
        self.remote.corrupt = True
        with self.assertRaisesRegex(fixture.BenchmarkError, "hash/size"):
            fixture.verify_or_cleanup(self.helper(report), report, self.work, lambda: None, cleanup=True)
        self.assertEqual(self.mutations(), [])
        self.assertIsNotNone(self.remote.data)
        self.assertEqual(len(list(self.work.glob("verify-*"))), 1)

    def test_scope_size_or_partial_cleanup_report_fails_before_helper(self):
        report = self.create()
        baseline = len(self.remote.calls)
        wrong = []
        for key, value in [("remote_root", report["remote_root"] + "/escape"), ("status", "cleaning")]:
            altered = copy.deepcopy(report); altered[key] = value; wrong.append(altered)
        altered = copy.deepcopy(report); altered["files"][fixture.NAME]["bytes"] += 1; wrong.append(altered)
        altered = copy.deepcopy(report); altered["remote_root"] = fixture.PREFIX + "0" * 32; wrong.append(altered)
        for altered in wrong:
            with self.assertRaises(fixture.BenchmarkError):
                fixture.verify_or_cleanup(self.helper(altered), altered, self.work, lambda: None, cleanup=True)
        self.assertEqual(len(self.remote.calls), baseline)

    def test_failed_stage_save_and_low_space_do_not_mutate_remote(self):
        report = self.create()
        def failure():
            raise OSError("fake persistence failure")
        with self.assertRaises(OSError):
            fixture.verify_or_cleanup(self.helper(report), report, self.work, failure, cleanup=True)
        self.assertEqual(report["status"], "cleaning")
        self.assertEqual(self.mutations(), [])
        report["status"] = "ready"
        with patch.object(fixture.shutil, "disk_usage", return_value=SimpleNamespace(free=0)):
            with self.assertRaises(fixture.BenchmarkError):
                fixture.inspect(self.helper(report), report, self.work)
        self.assertEqual(self.mutations(), [])

    def test_create_requires_source_plus_staging_plus_managed_copy_and_reserve(self):
        # This verifies the guard using synthetic inputs; it does not establish
        # available space on the actual Mac. The CLI always reads disk_usage.
        free = 2 * fixture.SIZE + fixture.RESERVE
        with patch.object(fixture.shutil, "disk_usage", return_value=SimpleNamespace(free=free)):
            with self.assertRaisesRegex(fixture.BenchmarkError, "staging/cache"):
                fixture.run("create")
        self.assertEqual(self.remote.calls, [])
        fixture.getpass.getpass.assert_not_called()


if __name__ == "__main__":
    assert fixture.SIZE == 512 * 1024 * 1024
    unittest.main()
