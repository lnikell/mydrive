"""No-network acceptance guards for the real disposable mutation workflow."""
import copy
import hashlib
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from nas_benchmark import BenchmarkError
from nas_mutation_check import MutationTrial


class FakeRemote:
    """A small namespace oracle, with a real separate prepared identity.

    A final rename changes name/ChangeTime. Reconstructing a receipt from the
    final observation therefore fails these tests, even if bytes still match.
    """
    root = ".mydrive-transport-tests/mutations-123456781234423482341234567890ab"

    def __init__(self, fault=None):
        self.objects = {}
        self.prepared = {}
        self.calls = []
        self.reconciled = []
        self.counter = 0
        self.fault = fault

    def entry(self, path, directory=False, body=b""):
        self.counter += 1
        return {"name": path.rsplit("/", 1)[-1], "directory": directory,
                "bytes": len(body), "index_number": self.counter,
                "created_filetime": 1000 + self.counter, "modified_filetime": 2000 + self.counter,
                "changed_filetime": 3000 + self.counter, "attributes": 16 if directory else 32}

    @staticmethod
    def result(value, names=None):
        return SimpleNamespace(complete={"result": value}, names=[] if names is None else names)

    def rename(self, source, destination):
        value = self.objects.pop(source)
        value["entry"]["name"] = destination.rsplit("/", 1)[-1]
        value["entry"]["changed_filetime"] += 1
        self.objects[destination] = value
        return copy.deepcopy(value["entry"])

    def run(self, command, *arguments, expect_error=None):
        self.calls.append((command, list(map(str, arguments))))
        if command == "prepare":
            self.objects[self.root] = {"entry": self.entry(self.root, True), "body": b""}
            if self.fault in ("incomplete", "unknown"):
                path = self.root + "/unexpected"
                self.objects[path] = {"entry": self.entry(path, body=b"retain"), "body": b"retain"}
            return self.result({})
        if command == "list":
            path = arguments[0]
            if path not in self.objects:
                if expect_error == "not_found":
                    return self.result({})
                raise BenchmarkError("unexpected missing test directory")
            names = sorted(key.rsplit("/", 1)[-1] for key in self.objects
                           if key.rpartition("/")[0] == path)
            if self.fault == "incomplete":
                return self.result({"complete": False, "entries": 0}, [])
            if self.fault == "count":
                return self.result({"complete": True, "entries": len(names) + 1}, names)
            return self.result({"complete": True, "entries": len(names)}, names)
        if command == "read":
            Path(arguments[1]).write_bytes(self.objects[arguments[0]]["body"])
            return self.result({})
        if command == "cleanup":
            if any(key.startswith(self.root + "/") for key in self.objects):
                raise BenchmarkError("cleanup requires empty root")
            self.objects.pop(self.root)
            return self.result({})
        raise AssertionError("Unexpected test helper command: " + command)

    def run_request(self, operation):
        self.calls.append((operation["type"], copy.deepcopy(operation)))
        if operation["type"] == "stat":
            return self.result({"entry": copy.deepcopy(self.objects[operation["path"]]["entry"])})
        request = operation["request"]
        key, kind, path = request["operation_id"], request["kind"], request["path"]
        result = {"operation_id": key, "outcome": "committed", "code": "committed"}
        if operation["type"] == "reconcile":
            # Require the exact receipt seen before publication, not final Entry.
            if request.get("receipt", {}).get("staged") != self.prepared[key]:
                raise BenchmarkError("replay guessed the prepared receipt")
            current = self.objects[path]
            same = current["entry"]["index_number"] == self.prepared[key]["entry"]["index_number"]
            result["outcome"] = "committed" if same else "conflict"
            self.reconciled.append(result["outcome"])
            if same:
                result["entry"] = copy.deepcopy(current["entry"])
                result["sha256"] = hashlib.sha256(current["body"]).hexdigest()
                if self.fault == "replay_identity":
                    result["entry"]["index_number"] += 10000
            return self.result(result)
        if request.get("expected") is not None and self.objects.get(path, {}).get("entry") != request["expected"]:
            return self.result({**result, "outcome": "conflict", "code": "changed"})
        if kind in ("create_directory", "create_file", "replace_file"):
            stage = path.rpartition("/")[0] + "/.mydrive-" + key + ".stage"
            if not request.get("receipt"):
                body = Path(request["payload"]["source"]).read_bytes() if "payload" in request else b""
                self.objects[stage] = {"entry": self.entry(stage, kind == "create_directory", body), "body": body}
                artifact = {"path": stage, "entry": copy.deepcopy(self.objects[stage]["entry"]), "cleanup_safe": True}
                self.prepared[key] = copy.deepcopy(artifact)
                return self.result({**result, "outcome": "not_applied", "code": "prepared", "staged": artifact})
            if request["receipt"]["staged"] != self.prepared[key]:
                raise BenchmarkError("continuation changed its stage receipt")
            if kind == "replace_file":
                backup = path.rpartition("/")[0] + "/.mydrive-" + key + ".backup"
                result["archived"] = {"path": backup, "entry": self.rename(path, backup), "cleanup_safe": True}
            result["entry"] = self.rename(stage, path)
            return self.result(result)
        if kind == "move":
            result["entry"] = self.rename(path, request["destination"])
        elif kind == "cleanup":
            self.objects.pop(path, None)
        elif kind == "delete":
            if self.objects[path]["entry"]["directory"]:
                if any(key.startswith(path + "/") for key in self.objects):
                    raise BenchmarkError("test refuses nonempty directory delete")
                self.objects.pop(path)
            else:
                deleted = path.rpartition("/")[0] + "/.mydrive-" + key + ".deleted"
                result["archived"] = {"path": deleted, "entry": self.rename(path, deleted), "cleanup_safe": True}
        else:
            raise AssertionError("Unexpected mutation: " + kind)
        return self.result(result)


class MutationQualificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mydrive-mutation-guards-")
        self.work = Path(self.temporary.name)
        self.report = {"commits": [], "files": {}, "operations": []}
        self.saves = []

    def tearDown(self):
        self.temporary.cleanup()

    def trial(self, remote):
        return MutationTrial(remote, self.work, self.report,
                             lambda: self.saves.append(copy.deepcopy(self.report)))

    def test_roundtrip_reconciles_actual_prepared_identity_then_obsolete_conflict(self):
        remote = FakeRemote()
        self.trial(remote).run()
        self.assertEqual(self.report["status"], "passed")
        self.assertEqual(remote.reconciled, ["committed", "conflict"])
        self.assertEqual(remote.objects, {})
        self.assertIn("committed replay identity", self.report["checks"])

    def test_incomplete_listing_cannot_authorize_any_mutation_or_cleanup(self):
        remote = FakeRemote("incomplete")
        with self.assertRaisesRegex(BenchmarkError, "incomplete remote listing"):
            self.trial(remote).run()
        self.assertFalse(any(kind in ("mutate", "reconcile", "cleanup") for kind, _ in remote.calls))
        self.assertEqual(remote.objects[remote.root + "/unexpected"]["body"], b"retain")

    def test_count_mismatch_and_unknown_membership_stop_before_mutation(self):
        for fault in ("count", "unknown"):
            remote = FakeRemote(fault)
            with self.subTest(fault=fault), self.assertRaises(BenchmarkError):
                self.trial(remote).run()
            self.assertFalse(any(kind in ("mutate", "cleanup") for kind, _ in remote.calls))

    def test_wrong_reconciled_identity_retains_files_and_never_deletes(self):
        remote = FakeRemote("replay_identity")
        with self.assertRaisesRegex(BenchmarkError, "preserve verified identity"):
            self.trial(remote).run()
        self.assertTrue(any(key.endswith("Edited — café.txt") for key in remote.objects))
        self.assertFalse(any(kind == "cleanup" or (kind == "mutate" and call["request"]["kind"] == "delete")
                             for kind, call in remote.calls))

    def test_completed_ledger_is_immutable_when_result_is_changed_by_caller(self):
        remote = FakeRemote()
        trial = self.trial(remote)
        remote.run("prepare")
        result = trial.apply(trial.request("create_file", "file", body=b"hello"))
        expected = copy.deepcopy(self.report["commits"])
        result["entry"]["name"] = "caller changed its copy"
        self.assertEqual(self.report["commits"], expected)


if __name__ == "__main__":
    unittest.main()
