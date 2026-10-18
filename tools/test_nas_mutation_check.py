"""No-network acceptance guards for the real disposable mutation workflow."""
import copy
import hashlib
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from nas_benchmark import BenchmarkError
from nas_mutation_check import ACKNOWLEDGED_SAVE_CONTRACT, MutationTrial, confirmed_content


class FakeRemote:
    """A small namespace oracle, with separate allocation/prepared identities.

    A final rename changes name/ChangeTime. Reconstructing a receipt from the
    final observation therefore fails these tests, even if bytes still match.
    """
    root = ".mydrive-transport-tests/mutations-123456781234423482341234567890ab"

    def __init__(self, fault=None):
        self.objects = {}
        self.prepared = {}
        self.allocated = {}
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
        contract = request.get("save_contract")
        if contract is not None:
            result["save_contract"] = contract
        parents = [(path.rpartition("/")[0], request.get("parent"))]
        if kind == "move":
            parents.append((request["destination"].rpartition("/")[0], request.get("destination_parent")))
        for parent_path, expected_parent in parents:
            parent = self.objects.get(parent_path, {}).get("entry", {})
            identity = {field: parent.get(field) for field in ("index_number", "created_filetime")}
            if expected_parent != identity or parent.get("directory") is not True:
                return self.result({**result, "outcome": "conflict", "code": "parent_changed"})
        if operation["type"] == "reconcile":
            # Require the exact receipt seen before publication, not final Entry.
            origin = self.allocated[key] if contract else self.prepared[key]
            if request.get("receipt", {}).get("staged") != origin:
                raise BenchmarkError("replay guessed the prepared receipt")
            current = self.objects[path]
            same = current["entry"]["index_number"] == origin["entry"]["index_number"]
            result["outcome"] = "committed" if same else "conflict"
            self.reconciled.append(result["outcome"])
            if same:
                result["entry"] = copy.deepcopy(current["entry"])
                self.content_result(result, current["body"], contract, reconcile=True)
                if self.fault == "replay_identity":
                    result["entry"]["index_number"] += 10000
            return self.result(result)
        if request.get("expected") is not None and self.objects.get(path, {}).get("entry") != request["expected"]:
            return self.result({**result, "outcome": "conflict", "code": "changed"})
        if kind in ("create_directory", "create_file", "replace_file"):
            stage = path.rpartition("/")[0] + "/.mydrive-" + key + ".stage"
            if not request.get("receipt"):
                self.objects[stage] = {"entry": self.entry(stage, kind == "create_directory"), "body": b""}
                phase = "prepared" if kind == "create_directory" else "allocated"
                artifact = {"path": stage, "entry": copy.deepcopy(self.objects[stage]["entry"]),
                            "cleanup_safe": True, "phase": phase, "security_sha256": "a" * 64}
                if contract:
                    artifact["save_contract"] = contract
                if phase == "allocated":
                    self.allocated[key] = copy.deepcopy(artifact)
                    if self.fault == "allocation_security":
                        artifact.pop("security_sha256")
                    elif self.fault == "allocation_nonempty":
                        artifact["entry"]["bytes"] = 1
                    elif self.fault == "allocation_contract":
                        artifact.pop("save_contract", None)
                else:
                    self.prepared[key] = copy.deepcopy(artifact)
                return self.result({**result, "outcome": "not_applied", "code": phase, "staged": artifact})
            if request["receipt"]["staged"].get("phase") == "allocated":
                if request["receipt"]["staged"] != self.allocated[key]:
                    raise BenchmarkError("continuation changed its allocation receipt")
                body = Path(request["payload"]["source"]).read_bytes()
                self.objects[stage]["body"] = body
                self.objects[stage]["entry"]["bytes"] = len(body)
                self.objects[stage]["entry"]["changed_filetime"] += 1
                artifact = {**self.allocated[key], "entry": copy.deepcopy(self.objects[stage]["entry"]), "phase": "prepared"}
                self.prepared[key] = copy.deepcopy(artifact)
                if not contract or self.fault == "v2_prepared":
                    return self.result({**result, "outcome": "not_applied", "code": "prepared", "staged": artifact})
            elif request["receipt"]["staged"] != self.prepared[key]:
                raise BenchmarkError("continuation changed its stage receipt")
            if kind == "replace_file":
                backup = path.rpartition("/")[0] + "/.mydrive-" + key + ".backup"
                result["archived"] = {"path": backup, "entry": self.rename(path, backup), "cleanup_safe": True}
            result["entry"] = self.rename(stage, path)
            if contract:
                self.content_result(result, body, contract)
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

    def content_result(self, result, body, contract, *, reconcile=False):
        digest = hashlib.sha256(body).hexdigest()
        if not contract:
            result["sha256"] = digest
            return
        evidence = {"kind": "remote_sha256" if reconcile else "smb_acknowledged",
                    "bytes": len(body), "sha256": digest}
        result["content_evidence"] = evidence
        if self.fault == "v2_wrong_role" and not reconcile:
            evidence["kind"] = "remote_sha256"
        if self.fault == "v2_reconcile_ack" and reconcile:
            evidence["kind"] = "smb_acknowledged"
        if self.fault == "v2_missing_echo":
            result.pop("save_contract")
        if self.fault == "v2_legacy_sha":
            result["sha256"] = digest
        if self.fault == "v2_extra_evidence":
            evidence["trusted"] = True
        if self.fault == "v2_wrong_creator":
            result["entry"]["index_number"] += 10000
        if self.fault == "v2_directory":
            result["entry"]["directory"] = True
        if self.fault == "v2_terminal_stage":
            result["staged"] = copy.deepcopy(next(iter(self.allocated.values())))


class MutationQualificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mydrive-mutation-guards-")
        self.work = Path(self.temporary.name)
        self.report = {"commits": [], "files": {}, "operations": []}
        self.saves = []

    def tearDown(self):
        self.temporary.cleanup()

    def trial(self, remote, *, acknowledged=False):
        return MutationTrial(remote, self.work, self.report,
                             lambda: self.saves.append(copy.deepcopy(self.report)),
                             save_contract=ACKNOWLEDGED_SAVE_CONTRACT if acknowledged else None)

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

    def test_request_freezes_parent_identity_and_refuses_a_same_path_replacement(self):
        remote = FakeRemote()
        trial = self.trial(remote)
        remote.run("prepare")
        request = trial.request("create_file", "file", body=b"retain locally")
        saved = copy.deepcopy(request["parent"])
        remote.objects[remote.root]["entry"] = remote.entry(remote.root, True)
        with self.assertRaisesRegex(BenchmarkError, "parent_changed"):
            trial.apply(request)
        self.assertEqual(request["parent"], saved)
        self.assertEqual(set(remote.objects), {remote.root})

    def test_allocation_is_empty_and_exact_receipt_precedes_payload_transfer(self):
        remote = FakeRemote()
        trial = self.trial(remote)
        remote.run("prepare")
        trial.apply(trial.request("create_file", "file", body=b"verified body"))
        calls = [value["request"] for kind, value in remote.calls if kind == "mutate"]
        self.assertEqual(len(calls), 3)
        allocation = calls[1]["receipt"]["staged"]
        self.assertEqual(allocation["phase"], "allocated")
        self.assertEqual(allocation["entry"]["bytes"], 0)
        self.assertEqual(calls[2]["receipt"]["staged"]["phase"], "prepared")
        self.assertEqual(remote.objects[remote.root + "/file"]["body"], b"verified body")

    def test_invalid_allocation_receipt_stops_before_payload_continuation(self):
        for fault in ("allocation_security", "allocation_nonempty"):
            with self.subTest(fault=fault):
                remote = FakeRemote(fault)
                trial = self.trial(remote)
                remote.run("prepare")
                with self.assertRaisesRegex(BenchmarkError, "verified continuation"):
                    trial.apply(trial.request("create_file", "file", body=b"retained"))
                self.assertEqual(sum(kind == "mutate" for kind, _ in remote.calls), 1)
                self.assertNotIn(remote.root + "/file", remote.objects)
                self.assertTrue(remote.allocated)

    def test_acknowledged_workflow_uses_original_allocated_origin_and_strict_replay(self):
        remote = FakeRemote()
        self.trial(remote, acknowledged=True).run()
        self.assertEqual(self.report["status"], "passed")
        self.assertEqual(remote.reconciled, ["committed", "conflict"])
        self.assertEqual(remote.objects, {})
        payload_requests = [op["request"] for kind, op in remote.calls
                            if kind in ("mutate", "reconcile") and "payload" in op["request"]]
        self.assertTrue(payload_requests)
        self.assertTrue(all(request["save_contract"] == ACKNOWLEDGED_SAVE_CONTRACT for request in payload_requests))
        namespace_requests = [op["request"] for kind, op in remote.calls
                              if kind in ("mutate", "reconcile") and "payload" not in op["request"]]
        self.assertTrue(all("save_contract" not in request for request in namespace_requests))
        committed = next(row for row in self.report["commits"] if row["request"]["kind"] == "create_file")
        self.assertEqual(committed["request"]["receipt"]["staged"], remote.allocated[committed["request"]["operation_id"]])
        self.assertNotIn("staged", committed["result"])
        self.assertNotIn("sha256", committed["result"])
        self.assertEqual(committed["result"]["content_evidence"]["kind"], "smb_acknowledged")

    def test_malformed_v2_success_retains_effect_before_any_read_or_cleanup(self):
        for fault in ("v2_wrong_role", "v2_missing_echo", "v2_legacy_sha", "v2_extra_evidence",
                      "v2_wrong_creator", "v2_terminal_stage", "v2_directory"):
            with self.subTest(fault=fault):
                remote = FakeRemote(fault)
                trial = self.trial(remote, acknowledged=True)
                remote.run("prepare")
                with self.assertRaises(BenchmarkError):
                    trial.apply(trial.request("create_file", "file", body=b"retain after malformed terminal"))
                self.assertEqual(remote.objects[remote.root + "/file"]["body"], b"retain after malformed terminal")
                self.assertFalse(any(kind in ("read", "cleanup", "reconcile") for kind, _ in remote.calls))

    def test_reconcile_cannot_claim_ack_and_never_reaches_further_read_or_deletion(self):
        remote = FakeRemote("v2_reconcile_ack")
        with self.assertRaisesRegex(BenchmarkError, "actual role"):
            self.trial(remote, acknowledged=True).run()
        self.assertEqual(sum(kind == "read" for kind, _ in remote.calls), 1)
        self.assertFalse(any(kind == "cleanup" or (kind == "mutate" and op["request"]["kind"] == "delete")
                             for kind, op in remote.calls))
        self.assertTrue(any(path.endswith("Edited — café.txt") for path in remote.objects))

    def test_v2_cannot_relabel_unbound_allocation_or_receive_legacy_prepared_checkpoint(self):
        for fault in ("allocation_contract", "v2_prepared"):
            remote = FakeRemote(fault)
            trial = self.trial(remote, acknowledged=True)
            remote.run("prepare")
            with self.subTest(fault=fault), self.assertRaises(BenchmarkError):
                trial.apply(trial.request("create_file", "file", body=b"retain locally"))
            self.assertNotIn(remote.root + "/file", remote.objects)
            self.assertFalse(any(kind in ("read", "cleanup") for kind, _ in remote.calls))

    def test_shared_proof_validator_has_exact_role_shape_and_legacy_semantics(self):
        payload = {"bytes": 3, "sha256": "a" * 64}
        legacy = {"outcome": "committed", "code": "committed", "entry": {"bytes": 3}, "sha256": "a" * 64}
        self.assertTrue(confirmed_content(legacy, payload))
        ack = {**legacy, "sha256": None, "save_contract": ACKNOWLEDGED_SAVE_CONTRACT,
               "content_evidence": {"kind": "smb_acknowledged", "bytes": 3, "sha256": "a" * 64}}
        self.assertTrue(confirmed_content(ack, payload, save_contract=ACKNOWLEDGED_SAVE_CONTRACT))
        self.assertFalse(confirmed_content(ack, payload))
        self.assertFalse(confirmed_content(ack, payload, save_contract=ACKNOWLEDGED_SAVE_CONTRACT, reconcile=True))
        recovery = copy.deepcopy(ack); recovery["content_evidence"]["kind"] = "remote_sha256"
        self.assertTrue(confirmed_content(recovery, payload, save_contract=ACKNOWLEDGED_SAVE_CONTRACT, reconcile=True))
        for field, value in (("bytes", True), ("bytes", 3.0), ("bytes", -1), ("sha256", "BAD"),
                             ("sha256", "b" * 64), ("kind", "unknown"), ("trusted", True)):
            changed = copy.deepcopy(ack); changed["content_evidence"][field] = value
            with self.subTest(field=field, value=value):
                self.assertFalse(confirmed_content(changed, payload, save_contract=ACKNOWLEDGED_SAVE_CONTRACT))


if __name__ == "__main__":
    unittest.main()
