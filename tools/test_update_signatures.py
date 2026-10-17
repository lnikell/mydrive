"""Real pinned Sparkle signing/appcast tools against a disposable local app."""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

from release import verify_signatures
from release_support import ROOT, ReleaseError, validate_appcast


class SparkleSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sparkle = ROOT / ".build/dependencies/Sparkle-2.10.0"
        if not (cls.sparkle / "bin/sign_update").is_file():
            raise unittest.SkipTest("Run tools/fetch-sparkle.py to enable real Sparkle tool tests.")
        cls.temporary = tempfile.TemporaryDirectory(prefix="mydrive-sparkle-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        # Public RFC 8032 test vector, used only in this disposable fixture.
        seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        cls.public = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
        cls.key = cls.root / "test-key"
        cls.key.write_bytes(base64.b64encode(seed))
        cls.key.chmod(0o600)
        cls.executable = cls.root / "key-check"
        subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(ROOT / ".build/mac-adapter-tests/ModuleCache"),
                        str(ROOT / "tools/check-sparkle-key.swift"), "-o", str(cls.executable)], check=True, capture_output=True)

    def invoke(self, *args):
        return subprocess.run([str(x) for x in args], capture_output=True, timeout=60)

    def test_private_key_matches_configured_public_key_and_rejects_wrong_key(self):
        result = subprocess.run([str(self.executable), self.public], input=self.key.read_bytes(), capture_output=True)
        self.assertEqual(result.returncode, 0)
        wrong = base64.b64encode(b"x" * 32).decode()
        result = subprocess.run([str(self.executable), wrong], input=self.key.read_bytes(), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout + result.stderr, b"")

    def test_real_archive_and_feed_signatures_reject_tampering(self):
        with tempfile.TemporaryDirectory(prefix="appcast-", dir=self.root) as temporary:
            work = Path(temporary)
            app = work / "MyDrive.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            shutil.copy2(self.executable, app / "Contents/MacOS/MyDrive")
            config = {"repository": "example/MyDrive", "sparkle_public_key": self.public}
            version = {"version": "0.2.0", "build": "2"}
            info = dict(CFBundleIdentifier="test.mydrive.release-fixture", CFBundleName="MyDrive",
                        CFBundleExecutable="MyDrive", CFBundlePackageType="APPL", CFBundleVersion="2",
                        CFBundleShortVersionString="0.2.0", LSMinimumSystemVersion="15.0", SUPublicEDKey=self.public,
                        SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                        SUFeedURL="https://github.com/example/MyDrive/releases/latest/download/appcast.xml")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            self.assertEqual(self.invoke("codesign", "--force", "--sign", "-", app).returncode, 0)
            output = work / "output"
            output.mkdir()
            archive = output / "MyDrive-0.2.0-arm64.zip"
            self.assertEqual(self.invoke("ditto", "-c", "-k", "--keepParent", app, archive).returncode, 0)
            archive.with_suffix(".md").write_text("A disposable signing fixture.\n")
            prefix = "https://github.com/example/MyDrive/releases/download/v0.2.0/"
            result = self.invoke(self.sparkle / "bin/generate_appcast", "--ed-key-file", self.key,
                                 "--maximum-versions", "1", "--maximum-deltas", "0",
                                 "--download-url-prefix", prefix, "--release-notes-url-prefix", prefix, output)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            validate_appcast(output / "appcast.xml", output, config, version)
            env = dict(os.environ, MYDRIVE_SPARKLE_KEY_FILE=str(self.key))
            from unittest.mock import patch
            with patch.dict(os.environ, env):
                verify_signatures(output, self.sparkle, config, version)
                archive.write_bytes(archive.read_bytes() + b"tampered")
                with self.assertRaises(ReleaseError):
                    verify_signatures(output, self.sparkle, config, version)
                archive.write_bytes(archive.read_bytes()[:-8])
                feed = output / "appcast.xml"
                feed.write_text(feed.read_text().replace("0.2.0", "0.2.1"))
                with self.assertRaises(ReleaseError):
                    verify_signatures(output, self.sparkle, config, version)


if __name__ == "__main__":
    unittest.main()
