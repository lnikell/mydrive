"""Exercise wrapper argument/configuration gates with no native app or NAS."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_host_diagnostic as host
import run_nas_check as transport
from nas_test_config import load_nas_test_config
from test_nas_test_config import PUBLIC_TARGET


class NASTestWrappers(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mydrive-wrapper-config-")
        self.root = Path(self.temporary.name)
        example = self.root / "config/nas-test.example.json"
        example.parent.mkdir()
        example.write_text(json.dumps(PUBLIC_TARGET))
        contents = self.root / "dist/MyDrive.app/Contents"
        contents.mkdir(parents=True)
        self.info = contents / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"MyDriveDevelopmentBuild": True,
                                             "MyDriveDevelopmentConnection": PUBLIC_TARGET}))
        self.runtime = self.root / ".runtime"
        self.runtime.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def test_contract_metadata_comes_only_from_isolated_config_and_password_only_stdin(self):
        for mode in ("probe", "list", "contract"):
            with self.subTest(mode=mode), patch.object(transport, "load_nas_test_config", lambda: load_nas_test_config(self.root)), \
                    patch.object(transport.sys, "argv", ["run_nas_check.py", mode]), \
                    patch.object(transport.getpass, "getpass", return_value="dummy-private-stdin"), \
                    patch.object(transport.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
                self.assertEqual(transport.main(), 0)
                command = run.call_args.args[0]
                values = run.call_args.kwargs
                self.assertEqual(values["input"], b"dummy-private-stdin\n")
                self.assertNotIn("dummy-private-stdin", str(command) + str(values["env"]))
                if mode == "contract":
                    self.assertEqual(values["env"]["NAS_TEST_HOST"], PUBLIC_TARGET["host"])
                    self.assertEqual(values["env"]["NAS_TEST_SHARE"], PUBLIC_TARGET["share"])
                    self.assertEqual(values["env"]["NAS_TEST_USER"], PUBLIC_TARGET["username"])
                    self.assertRegex(values["env"]["NAS_TEST_ROOT"], r"^\.mydrive-transport-tests/run-[0-9a-f]{12}$")
                else:
                    for key, value in PUBLIC_TARGET.items():
                        self.assertEqual(command[command.index("--" + key) + 1], value)

    def test_host_checks_bundle_and_saved_endpoint_before_password_or_launch(self):
        for fault in ("bundle", "saved"):
            with self.subTest(fault=fault):
                changed = dict(PUBLIC_TARGET, share="different-test-share")
                if fault == "bundle":
                    self.info.write_bytes(plistlib.dumps({"MyDriveDevelopmentBuild": True,
                                                         "MyDriveDevelopmentConnection": changed}))
                else:
                    self.info.write_bytes(plistlib.dumps({"MyDriveDevelopmentBuild": True,
                                                         "MyDriveDevelopmentConnection": PUBLIC_TARGET}))
                    saved = self.runtime / "unas-test/connection.json"
                    saved.parent.mkdir()
                    saved.write_text(json.dumps(dict(changed, domainID="unas-test", displayName="Test")))
                with patch.object(host, "PROJECT", self.root), \
                        patch.object(host, "load_nas_test_config", lambda: load_nas_test_config(self.root)), \
                        patch.object(host.sys, "argv", ["run_host_diagnostic.py", "connection"]), \
                        patch.object(host.getpass, "getpass") as password, \
                        patch.object(host.subprocess, "Popen") as launch, \
                        contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    host.main()
                password.assert_not_called()
                launch.assert_not_called()

    def test_host_uses_only_pipe_password_with_matching_public_config(self):
        captured = {}
        report = self.runtime / "connection-result.json"

        class FakeHost:
            pid = 123
            returncode = 0
            def __init__(self, command, **kwargs):
                captured.update(command=command, kwargs=kwargs)
            def communicate(self, password, timeout):
                captured["password"] = password
                report.write_text(json.dumps({"domainID": "unas-test", "stage": "complete"}))

        with patch.object(host, "PROJECT", self.root), \
                patch.object(host, "load_nas_test_config", lambda: load_nas_test_config(self.root)), \
                patch.object(host.sys, "argv", ["run_host_diagnostic.py", "connection"]), \
                patch.object(host.getpass, "getpass", return_value="dummy-private-stdin"), \
                patch.object(host.subprocess, "Popen", FakeHost), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(host.main(), 0)
        self.assertEqual(captured["password"], b"dummy-private-stdin")
        self.assertNotIn("dummy-private-stdin", str(captured["command"]) + report.read_text())
        self.assertEqual(captured["command"][-2:], ["--domain", "unas-test"])


if __name__ == "__main__":
    unittest.main()
