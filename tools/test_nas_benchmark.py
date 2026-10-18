#!/usr/bin/env python3
"""Local-only benchmark workflow tests; the fake helper never contacts a NAS."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import tempfile
import time
import unittest
from unittest.mock import patch
from test_nas_test_config import PUBLIC_TARGET

spec = importlib.util.spec_from_file_location("nas_benchmark", Path(__file__).with_name("nas_benchmark.py"))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)

FAKE_HELPER = r'''#!/usr/bin/env python3
import argparse, json, signal, shutil, sys, time
from pathlib import Path
p = argparse.ArgumentParser()
for name in ('host', 'share', 'username', 'test-root'):
    p.add_argument('--' + name, required=True)
p.add_argument('--password-stdin', action='store_true')
p.add_argument('--offset', type=int, default=0)
p.add_argument('--length', type=int)
p.add_argument('command')
p.add_argument('paths', nargs='*')
a = p.parse_args()
assert (a.host, a.share, a.username) == ('192.0.2.1:445', 'mydrive-test', 'mydrive-test')
assert sys.stdin.buffer.read() == b'not-a-real-password'
base = Path(__file__).with_name('remote')
root = base / a.test_root
fault_path = Path(__file__).with_name('fault')
fault = fault_path.read_text() if fault_path.exists() else ''
def emit(value):
    print(json.dumps(value), flush=True)
emit({'type':'connected', 'milliseconds':1, 'security':{'signing':True}})
if fault == 'hang':
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(999)
try:
    result = {}
    if a.command == 'list':
        path = base / a.paths[0]
        names = sorted(item.name for item in path.iterdir())
        if names:
            emit({'type':'page', 'entries':[{'name':name} for name in names]})
        result = {'complete':True, 'entries':len(names)}
    elif a.command == 'prepare':
        root.mkdir(parents=True)
    elif a.command == 'write':
        with open(a.paths[0], 'rb') as src, (root / a.paths[1]).open('xb') as dst:
            shutil.copyfileobj(src, dst, 65536)
        if fault == 'extra':
            (root / 'unexpected.txt').write_text('keep this evidence')
        result = {'bytes':(root / a.paths[1]).stat().st_size}
    elif a.command == 'read':
        path = base / a.paths[0]
        total = path.stat().st_size
        with path.open('rb') as src, open(a.paths[1], 'xb') as dst:
            src.seek(a.offset)
            remaining = a.length if a.length is not None else total - a.offset
            while remaining:
                block = src.read(min(65536, remaining))
                dst.write(block)
                remaining -= len(block)
            if fault == 'corrupt':
                dst.seek(0)
                dst.write(b'corrupt')
        result = {'bytes':Path(a.paths[1]).stat().st_size, 'entry':{'bytes':total, 'directory':False}}
    elif a.command == 'delete':
        (root / a.paths[0]).unlink()
    elif a.command == 'cleanup':
        root.rmdir()
    else:
        raise RuntimeError('unexpected command')
    emit({'type':'complete', 'operation_ms':1, 'result':result})
except FileNotFoundError:
    emit({'type':'error', 'code':'not_found', 'message':'missing fixture'})
    sys.exit(1)
'''


class BenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mydrive-benchmark-test-")
        self.base = Path(self.temporary.name)
        self.helper = self.base / "fake-helper"
        self.helper.write_text(FAKE_HELPER)
        self.helper.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def test_verified_roundtrip_removes_only_own_fixture_and_empty_directory(self):
        unrelated = self.base / "remote/.mydrive-transport-tests/previous-run/keep.txt"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("retain unrelated evidence")
        work = self.base / "evidence"
        report = benchmark.benchmark(self.helper, b"not-a-real-password", work, 256 * 1024, target=PUBLIC_TARGET)
        self.assertEqual(report["status"], "passed")
        self.assertTrue(report["checks"]["full_sha256_matches"])
        self.assertTrue(report["checks"]["range_sha256_matches"])
        self.assertFalse((self.base / "remote" / report["remote_root"]).exists())
        self.assertEqual(unrelated.read_text(), "retain unrelated evidence")
        self.assertEqual(sorted(path.name for path in work.iterdir()), ["report.json"])
        for operation in report["operations"]:
            self.assertGreater(operation["peak_rss_bytes"], 0)
        self.assertNotIn("not-a-real-password", (work / "report.json").read_text())

    def test_hash_failure_retains_local_and_remote_evidence(self):
        (self.base / "fault").write_text("corrupt")
        work = self.base / "evidence"
        with self.assertRaisesRegex(benchmark.BenchmarkError, "SHA-256"):
            benchmark.benchmark(self.helper, b"not-a-real-password", work, 256 * 1024, target=PUBLIC_TARGET)
        report = json.loads((work / "report.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertTrue((work / "source.bin").exists())
        self.assertTrue((work / "full.bin").exists())
        self.assertTrue((self.base / "remote" / report["remote_root"] / "payload.bin").exists())
        self.assertNotIn("delete", [op["command"] for op in report["operations"]])

    def test_timeout_terminates_and_reaps_uncooperative_helper(self):
        (self.base / "fault").write_text("hang")
        report = {"operations": []}
        helper = benchmark.Helper(self.helper, b"not-a-real-password",
                                  ".mydrive-transport-tests/benchmark-test", report, lambda: None, 0.2, target=PUBLIC_TARGET)
        with self.assertRaisesRegex(benchmark.BenchmarkError, "deadline"):
            helper.run("probe")
        with self.assertRaises(ProcessLookupError):
            os.kill(report["operations"][0]["pid"], 0)
        with self.assertRaises(ChildProcessError):
            os.waitpid(report["operations"][0]["pid"], os.WNOHANG)

    def test_unexpected_directory_entry_prevents_all_remote_deletion(self):
        (self.base / "fault").write_text("extra")
        work = self.base / "evidence"
        with self.assertRaisesRegex(benchmark.BenchmarkError, "unexpected entries"):
            benchmark.benchmark(self.helper, b"not-a-real-password", work, 256 * 1024, target=PUBLIC_TARGET)
        report = json.loads((work / "report.json").read_text())
        root = self.base / "remote" / report["remote_root"]
        self.assertTrue((root / "payload.bin").exists())
        self.assertEqual((root / "unexpected.txt").read_text(), "keep this evidence")
        self.assertNotIn("delete", [op["command"] for op in report["operations"]])

    def test_frame_limit_and_incomplete_output_are_rejected(self):
        frames = benchmark.Frames(lambda event: None)
        frames.feed(b"x" * benchmark.FRAME_BYTES)
        with self.assertRaisesRegex(benchmark.BenchmarkError, "8 MiB"):
            frames.feed(b"x")
        self.assertEqual(len(frames.pending), benchmark.FRAME_BYTES)
        with self.assertRaisesRegex(benchmark.BenchmarkError, "inside"):
            self.finish_partial()

    def test_full_native_input_pipe_still_has_deadline_and_reaps_child(self):
        self.helper.write_text("""#!/usr/bin/env python3
import signal, time
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
# Never consume stdin or produce stdout.
time.sleep(999)
""")
        report = {"operations": []}
        root = ".mydrive-transport-tests/mutations-123456781234423482341234567890ab"
        helper = benchmark.Helper(self.helper, b"not-a-real-password", root,
                                  report, lambda: None, 0.2, target=PUBLIC_TARGET)
        def watchdog(_signal, _frame):
            raise RuntimeError("native input blocked outside its operation deadline")
        previous = signal.signal(signal.SIGALRM, watchdog)
        started = time.monotonic()
        try:
            signal.setitimer(signal.ITIMER_REAL, 8)
            with self.assertRaisesRegex(benchmark.BenchmarkError, "deadline"):
                helper.run_request({"type": "stat", "path": root + "/" + "x" * 60000})
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
        self.assertLess(time.monotonic() - started, 6)
        pid = report["operations"][0]["pid"]
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        with self.assertRaises(ChildProcessError):
            os.waitpid(pid, os.WNOHANG)

    def test_native_operation_ledger_snapshots_nested_receipts_without_password(self):
        root = ".mydrive-transport-tests/mutations-123456781234423482341234567890ab"
        helper = benchmark.Helper(self.helper, b"not-a-real-password", root,
                                  {"operations": []}, lambda: None, target=PUBLIC_TARGET)
        operation = {"type": "mutate", "request": {"kind": "create_file", "path": root + "/file",
                     "operation_id": "12345678-1234-4234-8234-1234567890ab", "receipt": {},
                     "parent": {"index_number": 1, "created_filetime": 2}}}
        records = []
        def capture(_args, _input, record, _expect_error):
            records.append(record)
        with patch.object(helper, "_execute", side_effect=capture):
            helper.run_request(operation)
        operation["request"]["receipt"]["staged"] = {"path": root + "/later"}
        self.assertEqual(records[0]["operation"]["request"]["receipt"], {})
        self.assertNotIn("not-a-real-password", json.dumps(records))

    def test_native_parent_identity_and_root_stat_guards(self):
        root = ".mydrive-transport-tests/mutations-123456781234423482341234567890ab"
        helper = benchmark.Helper(self.helper, b"not-a-real-password", root,
                                  {"operations": []}, lambda: None, target=PUBLIC_TARGET)
        request = {"kind": "create_directory", "path": root + "/folder", "operation_id": "12345678-1234-4234-8234-1234567890ab"}
        with patch.object(helper, "_execute") as execute:
            helper.run_request({"type": "stat", "path": root})
            execute.assert_called_once()
            execute.reset_mock()
            for identity in (None, {}, {"index_number": True, "created_filetime": 2},
                             {"index_number": 1, "created_filetime": 0},
                             {"index_number": 2 ** 64, "created_filetime": 2}):
                with self.subTest(identity=identity), self.assertRaisesRegex(benchmark.BenchmarkError, "parent identity"):
                    helper.run_request({"type": "mutate", "request": {**request, "parent": identity}})
            execute.assert_not_called()
            with self.assertRaises(benchmark.BenchmarkError):
                helper.run_request({"type": "stat", "path": root + "-other"})

    def test_frozen_delete_scope_never_expands_generated_namespace(self):
        root = ".mydrive-transport-tests/mutations-123456781234423482341234567890ab"
        helper = benchmark.Helper(self.helper, b"not-a-real-password", root,
                                  {"operations": []}, lambda: None, target=PUBLIC_TARGET)
        identity = {"index_number": 1, "created_filetime": 2}
        scope = {"root_path": root + "/folder", "root": identity, "parent": identity}
        request = {"kind": "delete", "path": root + "/folder/file", "parent": identity,
                   "operation_id": "12345678-1234-4234-8234-1234567890ab", "delete_scope": scope}
        with patch.object(helper, "_execute") as execute:
            helper.run_request({"type": "stat", "path": scope["root_path"], "delete_scope": scope})
            helper.run_request({"type": "list", "path": scope["root_path"], "delete_scope": scope})
            helper.run_request({"type": "mutate", "request": request})
            self.assertEqual(execute.call_count, 3)
            execute.reset_mock()
            bad_requests = [
                {**request, "path": root + "/folder-other/file"},
                {**request, "kind": "create_file"},
                {**request, "path": root, "delete_scope": {**scope, "root_path": root}},
                {**request, "delete_scope": {**scope, "root_path": root + "-other"}},
                {**request, "delete_scope": {**scope, "parent": {**identity, "index_number": True}}},
            ]
            for invalid in bad_requests:
                with self.subTest(request=invalid), self.assertRaises(benchmark.BenchmarkError):
                    helper.run_request({"type": "mutate", "request": invalid})
            execute.assert_not_called()

    def test_acknowledged_contract_is_closed_and_does_not_expand_the_test_root(self):
        root = ".mydrive-transport-tests/mutations-123456781234423482341234567890ab"
        helper = benchmark.Helper(self.helper, b"not-a-real-password", root,
                                  {"operations": []}, lambda: None, target=PUBLIC_TARGET)
        request = {"kind": "create_file", "path": root + "/file",
                   "operation_id": "12345678-1234-4234-8234-1234567890ab",
                   "parent": {"index_number": 1, "created_filetime": 2},
                   "payload": {"source": str(self.base / "source"), "bytes": 1, "sha256": "a" * 64},
                   "save_contract": "acknowledged_smb_v2"}
        with patch.object(helper, "_execute") as execute:
            helper.run_request({"type": "mutate", "request": request})
            wire = json.loads(execute.call_args.args[1])
            self.assertEqual(wire["operation"]["request"]["save_contract"], "acknowledged_smb_v2")
            execute.reset_mock()
            for change in ({"save_contract": "unknown"}, {"save_contract": None},
                           {"kind": "cleanup"}, {"kind": "create_directory"},
                           {"payload": None}, {"path": root + "-other/file"}):
                with self.subTest(change=change), self.assertRaises(benchmark.BenchmarkError):
                    helper.run_request({"type": "mutate", "request": {**request, **change}})
            execute.assert_not_called()

    @staticmethod
    def finish_partial():
        frames = benchmark.Frames(lambda event: None)
        frames.feed(b"{}")
        frames.finish()


if __name__ == "__main__":
    unittest.main()
