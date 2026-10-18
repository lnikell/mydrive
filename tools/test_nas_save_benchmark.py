"""The speed report cannot accept a different completion contract or clean a failed save."""
import copy
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from nas_benchmark import BenchmarkError
from nas_mutation_check import ACKNOWLEDGED_SAVE_CONTRACT, confirmed_content
from nas_save_benchmark import run_trial


class SaveBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.payload = {"source": "/unused/generated-fixture", "bytes": 42, "sha256": "a" * 64}
        self.result = {"outcome": "committed", "code": "committed", "save_contract": "acknowledged_smb_v2",
                       "sha256": None, "entry": {"bytes": 42},
                       "content_evidence": {"kind": "smb_acknowledged", "bytes": 42, "sha256": "a" * 64}}

    def test_normal_save_evidence_cannot_be_replaced_by_legacy_or_recovery_hashes(self):
        self.assertTrue(confirmed_content(self.result, self.payload, save_contract=ACKNOWLEDGED_SAVE_CONTRACT))
        changes = [{"save_contract": None}, {"sha256": "a" * 64}, {"outcome": "uncertain"},
                   {"entry": None}, {"entry": {"bytes": 41}}, {"content_evidence": None}]
        for field, value in [("kind", "remote_sha256"), ("kind", "unknown"), ("bytes", 41),
                             ("bytes", 42.0), ("sha256", "b" * 64), ("trusted", True)]:
            evidence = {**self.result["content_evidence"], field: value}
            changes.append({"content_evidence": evidence})
        for change in changes:
            with self.subTest(change=change):
                self.assertFalse(confirmed_content({**self.result, **change}, self.payload,
                                                   save_contract=ACKNOWLEDGED_SAVE_CONTRACT))

    def test_invalid_completion_retains_fixture_before_readback_or_cleanup(self):
        result = copy.deepcopy(self.result)
        result["content_evidence"]["sha256"] = "b" * 64
        trial = SimpleNamespace(request=Mock(return_value={}), apply=Mock(return_value=result),
            verify_bytes=Mock(), cleanup_receipts=Mock(), assert_membership=Mock(),
            report={"operations": [], "timings": []}, save=Mock())
        with self.assertRaisesRegex(BenchmarkError, "retaining fixture"):
            run_trial(trial, Path(self.payload["source"]), 42, "a" * 64, 1)
        trial.apply.assert_called_once()
        trial.verify_bytes.assert_not_called()
        trial.cleanup_receipts.assert_not_called()
        self.assertEqual(trial.report["timings"], [])


if __name__ == "__main__":
    unittest.main()
