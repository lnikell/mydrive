"""Synthetic process failures only; no signing tools, credentials or network."""
import contextlib
import io
from pathlib import Path
import subprocess
import traceback
import unittest
from unittest.mock import patch

import release_support as release


class ReleaseProcessPrivacyTests(unittest.TestCase):
    def test_timeout_and_called_process_error_omit_arguments_and_captured_output(self):
        command = ["/usr/bin/security", "unlock-keychain", "-p", "synthetic-argument-secret"]
        output = "synthetic-stdout-secret"
        error_output = "synthetic-stderr-secret"
        failures = [subprocess.TimeoutExpired(command, 1, output=output, stderr=error_output),
                    subprocess.CalledProcessError(9, command, output=output, stderr=error_output)]
        for failure in failures:
            with self.subTest(kind=type(failure).__name__):
                printed = io.StringIO()
                with patch.object(release.subprocess, "run", side_effect=failure), \
                        contextlib.redirect_stdout(printed), contextlib.redirect_stderr(printed):
                    try:
                        release.run(command, capture=True)
                    except release.ReleaseError as error:
                        diagnostic = str(error) + "\n" + "".join(traceback.format_exception(type(error), error, error.__traceback__))
                    else:
                        self.fail("Process failure did not become a sanitized release error")
                for secret in [command[-1], output, error_output]:
                    self.assertNotIn(secret, diagnostic + printed.getvalue())
                self.assertNotIn("unlock-keychain", diagnostic)
                self.assertEqual(printed.getvalue(), "")
                self.assertIn("security", diagnostic)

    def test_nonzero_exit_including_git_never_echoes_stdout_or_stderr(self):
        for executable in ["security", "git"]:
            with self.subTest(executable=executable):
                command = [executable, "synthetic-argument-secret"]
                result = subprocess.CompletedProcess(command, 7, stdout="synthetic-stdout-secret", stderr="synthetic-stderr-secret")
                with patch.object(release.subprocess, "run", return_value=result), self.assertRaises(release.ReleaseError) as failure:
                    release.run(command, capture=True)
                self.assertEqual(str(failure.exception), executable + " failed (exit 7).")

    def test_success_preserves_text_input_environment_and_return_contract(self):
        command = [Path("/usr/bin/example"), "operation"]
        environment = {"TEST_ONLY": "synthetic"}
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess(command, 0, stdout=" result \n")) as run:
            self.assertEqual(release.run(command, capture=True, input="synthetic-input", env=environment, timeout=3), "result")
            self.assertEqual(run.call_args.args[0], ["/usr/bin/example", "operation"])
            self.assertEqual(run.call_args.kwargs["input"], "synthetic-input")
            self.assertIs(run.call_args.kwargs["env"], environment)
            self.assertEqual(run.call_args.kwargs["timeout"], 3)
            self.assertIsNone(release.run(command))


if __name__ == "__main__":
    unittest.main()
