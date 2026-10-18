import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("publication", Path(__file__).with_name("check-publication.py"))
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.command("init", "-q")
        self.write(".gitignore", (Path(__file__).resolve().parents[1] / ".gitignore").read_bytes())

    def command(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, check=True).stdout

    def write(self, path, data):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)

    def test_gitignore_keeps_local_docs_and_signing_data_out_of_add_all(self):
        private = ["docs/research/design.md", "docs/adr/decision.md", "docs/implementation-progress.md", "docs/future-plan.md",
                   "AGENTS.md", "GLOSSARY.md", ".agents/skills/release/SKILL.md", ".local/nas-test.json",
                   "nested/plans/experiment.txt", "nested/research/notes.html", "nested/adr/decision.txt",
                   "nested/.agents/skills/local/SKILL.md", "nested/AGENTS.md", "nested/architecture-review-1.html",
                   "signing.p12", "AuthKey.p8", ".env.local", "update-key", "secrets.json", "PLAN.txt", "notes.html",
                   "dist/MyDrive.app/executable", "Transport/target/helper"]
        public = ["README.md", "docs/releasing.md", "docs/ui-missing-features.md", "release/notes/0.2.0.md",
                  "MacApp/File.swift"]
        for path in private + public:
            self.write(path, b"example\n")
        self.command("add", ".")
        indexed = set(self.command("ls-files", "-z").decode().strip("\0").split("\0"))
        self.assertFalse(indexed & set(private))
        self.assertTrue(set(public) <= indexed)

    def test_force_added_plan_and_key_are_blocked_even_with_gitignore(self):
        self.write("docs/research/design.md", b"private planning")
        self.write("signing.key", b"private data")
        self.command("add", "--force", "docs/research/design.md", "signing.key")
        _, problems = publication.check(self.root)
        self.assertEqual({x[0] for x in problems}, {"docs/research/design.md", "signing.key"})

    def test_checks_index_even_when_working_copy_was_cleaned(self):
        token = b"ghp_" + b"a" * 36
        self.write("source.swift", token)
        self.command("add", "source.swift")
        self.write("source.swift", b"clean now")
        _, problems = publication.check(self.root)
        self.assertEqual(problems, [("source.swift", 1, "GitHub token")])
        self.assertNotIn(token.decode(), str(problems))

    def test_unknown_markdown_is_private_by_default_but_release_guide_is_public(self):
        self.assertTrue(publication.findings("design.md", b"plan"))
        self.assertTrue(publication.findings("docs/future.md", b"plan"))
        self.assertEqual(publication.findings("docs/releasing.md", b"release guide"), [])
        self.assertEqual(publication.findings("release/notes/1.2.3.md", b"release notes"), [])

    def test_private_key_markers_never_leak_into_diagnostics(self):
        value = b"-----BEGIN OPENSSH PRIVATE " + b"KEY-----\nsecret content"
        result = publication.findings("unexpected.txt", value)
        self.assertEqual(result, [(1, "private key material")])
        self.assertNotIn("secret content", str(result))

    def test_non_markdown_plans_and_raw_key_exports_are_rejected_by_path(self):
        for path in ("PLAN.txt", "notes.html", "folder/Planning.json", "update-key", "config/signing_key.txt",
                     "config/API-KEY", "config/secrets.json"):
            self.assertTrue(publication.findings(path, b"synthetic private value"), path)

    def test_nested_json_credentials_are_rejected_without_echoing_the_value(self):
        import json
        value = "synthetic-do-not-echo"
        for field in ("password", "api_key", "client_secret", "MYDRIVE_SPARKLE_PRIVATE_KEY",
                      "MYDRIVE_CERTIFICATE_P12_BASE64", "MYDRIVE_CERTIFICATE_PASSWORD", "MYDRIVE_NOTARY_KEY_BASE64"):
            result = publication.findings("config/service.json", json.dumps({"accounts": [{field: value}]}).encode())
            self.assertEqual(result, [(None, "populated credential field in JSON")])
            self.assertNotIn(value, str(result))
        self.assertEqual(publication.findings("config/example.json", b'{"password": null, "api_key": ""}'), [])

    def test_public_update_key_is_allowed_but_private_config_fields_are_not(self):
        import json
        config = {x: None for x in publication.PUBLIC_CONFIG_KEYS}
        config["sparkle_public_key"] = "public verification key"
        self.assertEqual(publication.findings("release/config.json", json.dumps(config).encode()), [])
        config["private_key"] = "never publish"
        self.assertTrue(publication.findings("release/config.json", json.dumps(config).encode()))


if __name__ == "__main__":
    unittest.main()
