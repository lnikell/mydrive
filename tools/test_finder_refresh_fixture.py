#!/usr/bin/env python3
"""Guard the one-file refresh trial locally; no subprocess or network is used."""
import copy
import hashlib
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import uuid

import finder_fixture as fixture
import finder_refresh_fixture as refresh
from test_finder_fixture import FakeHelper
from test_nas_test_config import PUBLIC_TARGET


class RefreshHelper(FakeHelper):
    def __init__(self, spec, root, state):
        super().__init__(spec, root)
        self.state = state
        self.uncertain_delete = False
        self.uncertain_write = False

    def run(self, command, *arguments, expect_error=None):
        if command == "delete":
            assert arguments == (refresh.README,) and self.state["stage"] == "removing"
            result = super().run(command, *arguments)
            if self.uncertain_delete:
                self.uncertain_delete = False
                raise fixture.BenchmarkError("fake uncertain deletion")
            return result
        if command == "write":
            source, name = arguments
            assert name == refresh.README and self.state["stage"] == "restoring"
            self.calls.append((command, str(source), name))
            if name in self.payload:
                raise fixture.BenchmarkError("exclusive destination exists")
            self.payload[name] = Path(source).read_bytes()
            if self.uncertain_write:
                self.uncertain_write = False
                raise fixture.BenchmarkError("fake uncertain upload")
            return SimpleNamespace(complete={"result": {"bytes": len(self.payload[name])}})
        return super().run(command, *arguments, expect_error=expect_error)


class RefreshFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mydrive-refresh-guards-")
        self.spec = fixture.fixture("basic", Path(self.temporary.name))
        (self.spec.work / "text.txt").write_text(fixture.TEXT)
        root = ".mydrive-transport-tests/finder-" + uuid.uuid4().hex
        self.state = {"target": dict(PUBLIC_TARGET), "version": 1, "remote_root": root, "stage": "checking", "operations": []}
        self.helper = RefreshHelper(self.spec, root, self.state)
        self.report = {"target": dict(PUBLIC_TARGET), "remote_root": root, "status": "ready", "operations": [],
                       "files": {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                                 for name, data in self.helper.payload.items()}}
        self.state["manifest_sha256"] = refresh.manifest_digest(self.report)
        self.saved = []

    def tearDown(self):
        self.temporary.cleanup()

    def run_mode(self, mode):
        return refresh.exercise(mode, self.spec, self.report, self.state, self.helper,
                                lambda: self.saved.append(copy.deepcopy(self.state)))

    def mutations(self):
        return [call for call in self.helper.calls if call[0] in ("delete", "write", "cleanup")]

    def test_changed_recorded_state_target_blocks_all_helper_calls(self):
        self.state["target"] = dict(PUBLIC_TARGET, host="192.0.2.2:445")
        with self.assertRaises(fixture.BenchmarkError):
            self.run_mode("remove-readme")
        self.assertEqual(self.helper.calls, [])

    def test_remove_and_restore_verify_full_baseline_and_survivors_with_only_literal_target(self):
        original = dict(self.helper.payload)
        self.run_mode("remove-readme")
        first_delete = next(index for index, call in enumerate(self.helper.calls) if call[0] == "delete")
        self.assertEqual(sum(call[0] == "read" for call in self.helper.calls[:first_delete]), 3)
        self.assertEqual(self.mutations(), [("delete", refresh.README)])
        self.assertEqual(self.state["stage"], "removed")
        self.assertEqual(self.saved[0]["stage"], "removing")
        self.assertEqual(self.helper.directories, {"Offline folder"})
        self.run_mode("restore-readme")
        self.assertEqual(self.helper.payload, original)
        self.assertEqual(self.state["stage"], "restored")
        self.assertEqual([call[0] for call in self.mutations()], ["delete", "write"])
        self.assertEqual([state["stage"] for state in self.saved], ["removing", "removed", "restoring", "restored"])
        self.assertEqual(list(self.spec.work.glob("verify-*")), [])

    def test_uncertain_delete_inspects_survivors_instead_of_deleting_again(self):
        self.helper.uncertain_delete = True
        with self.assertRaisesRegex(fixture.BenchmarkError, "uncertain"):
            self.run_mode("remove-readme")
        self.assertEqual(self.state["stage"], "removing")
        self.run_mode("remove-readme")
        self.assertEqual(self.state["stage"], "removed")
        self.assertEqual(self.mutations(), [("delete", refresh.README)])

    def test_uncertain_upload_and_already_restored_content_are_never_overwritten(self):
        self.run_mode("remove-readme")
        self.helper.uncertain_write = True
        with self.assertRaisesRegex(fixture.BenchmarkError, "uncertain"):
            self.run_mode("restore-readme")
        self.assertEqual(self.state["stage"], "restoring")
        self.run_mode("restore-readme")
        self.run_mode("restore-readme")
        self.assertEqual(self.state["stage"], "restored")
        self.assertEqual([call[0] for call in self.mutations()], ["delete", "write"])
        self.assertEqual(self.helper.payload[refresh.README], fixture.TEXT.encode())

    def test_unknown_incomplete_or_changed_survivors_block_restore(self):
        for fault in ("extra", "incomplete", "corrupt", "missing-directory"):
            with self.subTest(fault=fault):
                self.temporary.cleanup()
                self.setUp()
                try:
                    self.run_mode("remove-readme")
                    self.helper.calls.clear()
                    if fault == "extra":
                        self.helper.payload["unrelated.txt"] = b"retain"
                    elif fault == "incomplete":
                        self.helper.list_faults[""] = lambda names, result: (names, dict(result, complete=False))
                    elif fault == "corrupt":
                        self.helper.corrupt = "Offline folder/Offline sample.bin"
                    else:
                        self.helper.directories.remove("Offline folder")
                    with self.assertRaises(fixture.BenchmarkError):
                        self.run_mode("restore-readme")
                    self.assertEqual(self.mutations(), [])
                    self.assertNotIn(refresh.README, self.helper.payload)
                finally:
                    self.tearDown()

    def test_report_state_or_restore_source_mismatch_blocks_all_helper_calls(self):
        for field, value in [("remote_root", "another-root"), ("manifest_sha256", "wrong"), ("stage", "unknown")]:
            with self.subTest(field=field):
                previous = self.state[field]
                self.state[field] = value
                with self.assertRaises(fixture.BenchmarkError):
                    self.run_mode("remove-readme")
                self.assertEqual(self.helper.calls, [])
                self.state[field] = previous
        (self.spec.work / "text.txt").write_text("changed recovery bytes")
        with self.assertRaises(fixture.BenchmarkError):
            self.run_mode("remove-readme")
        self.assertEqual(self.helper.calls, [])

    def test_unrecorded_missing_readme_or_failed_stage_save_never_deletes(self):
        del self.helper.payload[refresh.README]
        with self.assertRaises(fixture.BenchmarkError):
            self.run_mode("remove-readme")
        self.assertEqual(self.mutations(), [])
        self.helper.payload[refresh.README] = fixture.TEXT.encode()
        def failed_save():
            raise OSError("fake state persistence failure")
        with self.assertRaises(OSError):
            refresh.exercise("remove-readme", self.spec, self.report, self.state, self.helper, failed_save)
        self.assertEqual(self.mutations(), [])


if __name__ == "__main__":
    unittest.main()
