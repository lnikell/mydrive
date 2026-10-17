"""Local metadata validation only; no helper, credentials or network access."""
import json
import os
from pathlib import Path
import tempfile
import unittest

from nas_test_config import load_nas_test_config, validate_nas_test_config

PUBLIC_TARGET = {"host": "192.0.2.1:445", "share": "mydrive-test", "username": "mydrive-test"}


class NASTestConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mydrive-public-config-")
        self.root = Path(self.temporary.name)
        self.example = self.root / "config/nas-test.example.json"
        self.local = self.root / ".local/nas-test.json"
        self.example.parent.mkdir()
        self.local.parent.mkdir()
        self.example.write_text(json.dumps(PUBLIC_TARGET))

    def tearDown(self):
        self.temporary.cleanup()

    def test_public_example_and_explicit_local_precedence(self):
        self.assertEqual(load_nas_test_config(self.root), PUBLIC_TARGET)
        local = dict(PUBLIC_TARGET, host="192.0.2.2:445")
        self.local.write_text(json.dumps(local))
        self.assertEqual(load_nas_test_config(self.root), local)
        self.assertEqual(json.loads(self.example.read_text()), PUBLIC_TARGET)

    def test_exact_nonsecret_schema_rejects_password_unknown_duplicate_and_bad_types(self):
        invalid = [None, [], {}, dict(PUBLIC_TARGET, password="dummy-rejected-input"),
                   dict(PUBLIC_TARGET, unknown="extra"), {key: None for key in PUBLIC_TARGET}]
        for value in invalid:
            with self.subTest(value=type(value).__name__), self.assertRaises(ValueError):
                validate_nas_test_config(value)
        self.local.write_text('{"host":"192.0.2.2:445","host":"192.0.2.3:445","share":"test","username":"test"}')
        with self.assertRaisesRegex(ValueError, "duplicate"):
            load_nas_test_config(self.root)

    def test_utf8_bounds_control_characters_and_unchanged_valid_values(self):
        for invalid in ["", "  ", "x" * 1025, "é" * 513, "line\nfeed", "tab\t", "nul\0", "del\x7f", "\ud800"]:
            for field in PUBLIC_TARGET:
                with self.subTest(field=field, size=len(invalid)), self.assertRaises(ValueError):
                    validate_nas_test_config(dict(PUBLIC_TARGET, **{field: invalid}))
        value = dict(PUBLIC_TARGET, share=" é" + "x" * 1021)
        validated = validate_nas_test_config(value)
        self.assertEqual(validated, value)
        validated["share"] = "changed copy"
        self.assertNotEqual(value, validated)

    def test_invalid_local_never_falls_back_or_creates_files(self):
        for contents in [b"{", b" " * 4097, json.dumps(PUBLIC_TARGET).encode("utf-16"), b"\xff"]:
            self.local.write_bytes(contents)
            with self.assertRaises(ValueError):
                load_nas_test_config(self.root)
        self.local.unlink()
        self.local.symlink_to(self.example)
        with self.assertRaises(OSError):
            load_nas_test_config(self.root)
        self.local.unlink()
        self.local.mkdir()
        with self.assertRaises(ValueError):
            load_nas_test_config(self.root)
        self.local.rmdir()
        os.mkfifo(self.local)
        with self.assertRaises(ValueError):
            load_nas_test_config(self.root)

    def test_missing_metadata_fails_without_writing_a_default(self):
        self.example.unlink()
        with self.assertRaises(FileNotFoundError):
            load_nas_test_config(self.root)
        self.assertFalse(self.local.exists())
        self.assertFalse(self.example.exists())


if __name__ == "__main__":
    unittest.main()
