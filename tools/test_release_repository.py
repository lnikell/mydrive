"""Exercise effective push URL validation against local Git configuration only."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from release_repository import validate_origin
from release_support import ReleaseError


class ReleaseRepositoryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mydrive-origin-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        environment = patch.dict(os.environ, {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
        environment.start()
        self.addCleanup(environment.stop)
        self.git("init", "--quiet")
        self.config = {"repository": "example/MyDrive"}

    def git(self, *arguments):
        subprocess.run(["git", "-C", str(self.root), *arguments], check=True, capture_output=True)

    def test_standard_https_and_ssh_origins_match_case_insensitively(self):
        self.git("remote", "add", "origin", "https://github.com/example/MyDrive.git")
        for url in ("https://github.com/example/MyDrive.git", "https://github.com:443/EXAMPLE/mydrive/",
                    "git@github.com:example/MyDrive.git", "ssh://git@github.com:22/example/MyDrive.git"):
            with self.subTest(url=url):
                self.git("remote", "set-url", "origin", url)
                validate_origin(self.config, self.root)

    def test_every_push_url_must_match_even_when_fetch_url_is_correct(self):
        self.git("remote", "add", "origin", "https://github.com/example/MyDrive.git")
        self.git("config", "--add", "remote.origin.pushurl", "git@github.com:example/MyDrive.git")
        self.git("config", "--add", "remote.origin.pushurl", "git@github.com:another/project.git")
        with self.assertRaisesRegex(ReleaseError, "Every effective origin push URL"):
            validate_origin(self.config, self.root)

    def test_git_push_rewrite_cannot_redirect_publication(self):
        self.git("remote", "add", "origin", "https://github.com/example/MyDrive.git")
        self.git("config", "url.https://github.com/another/.pushInsteadOf", "https://github.com/example/")
        with self.assertRaises(ReleaseError):
            validate_origin(self.config, self.root)

    def test_missing_origin_is_actionable_without_network_access(self):
        with self.assertRaisesRegex(ReleaseError, "Configure origin"):
            validate_origin(self.config, self.root)

    def test_credentials_wrong_host_and_ambiguous_urls_are_rejected_without_echo(self):
        self.git("remote", "add", "origin", "https://github.com/example/MyDrive.git")
        for url in ("https://" + "dummy:never-print-this@" + "github.com/example/MyDrive.git",
                    "https://enterprise.example/example/MyDrive.git", "https://github.com/example/MyDrive?other=1",
                    "file:///tmp/example/MyDrive", "ssh://somebody@github.com/example/MyDrive.git"):
            with self.subTest(url=url):
                self.git("remote", "set-url", "origin", url)
                with self.assertRaises(ReleaseError) as failure:
                    validate_origin(self.config, self.root)
                self.assertNotIn("never-print-this", str(failure.exception))
                self.assertNotIn(url, str(failure.exception))


if __name__ == "__main__":
    unittest.main()
