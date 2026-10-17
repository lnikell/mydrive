"""No network/signing: real local notice files and a resolved Cargo graph."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import third_party_notices as notices


class ThirdPartyNoticesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mydrive-notices-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "release").mkdir()
        (self.root / "release/version.json").write_text(json.dumps(dict(version="0.2.0", build=2)))
        (self.root / "LICENSE").write_text("MyDrive complete MIT license fixture.\n")
        (self.root / "Transport").mkdir()
        self.sparkle = self.root / "Sparkle-2.10.0"
        self.sparkle.mkdir()
        (self.sparkle / "LICENSE").write_text("Complete Sparkle license fixture.\n")
        (self.sparkle / ".mydrive-sparkle.json").write_text(json.dumps(dict(version="2.10.0", sha256="a" * 64)))
        self.packages = []
        self.nodes = []
        self.add_package("root", licensed=False)
        self.add_package("ordinary")
        self.add_package("build-helper")
        self.add_package("shared")
        self.add_package("dev-only", licensed=False)
        self.add_package("wrong-target", licensed=False)
        self.edge("root", "ordinary", None)
        self.edge("root", "build-helper", "build")
        self.edge("root", "dev-only", "dev")
        self.edge("root", "shared", "dev", None)
        self.edge("ordinary", "shared", None)
        self.metadata = dict(packages=self.packages, resolve=dict(root="root", nodes=self.nodes))

    def add_package(self, name, licensed=True):
        path = self.root / "private-cargo-cache" / name
        path.mkdir(parents=True)
        (path / "Cargo.toml").write_text("[package]\n")
        if licensed:
            (path / "LICENSE-MIT").write_text(f"Complete {name} license, including all trailing terms.\n")
        self.packages.append(dict(id=name, name=name, version="1.0.0", license="MIT", license_file=None,
                                  manifest_path=str(path / "Cargo.toml")))
        self.nodes.append(dict(id=name, deps=[]))
        return path

    def edge(self, parent, child, *kinds):
        next(n for n in self.nodes if n["id"] == parent)["deps"].append(dict(pkg=child, dep_kinds=[dict(kind=k, target=None) for k in kinds]))

    def package(self, name="ordinary"):
        return next(p for p in self.packages if p["name"] == name)

    def generated(self, metadata=None):
        with patch.object(notices, "cargo_metadata", return_value=metadata or self.metadata):
            return notices.generate(self.root, self.sparkle)

    def test_locked_offline_metadata_uses_only_the_release_target_and_local_cargo_home(self):
        def cargo(arguments, **kwargs):
            self.assertEqual(arguments, ["cargo", "metadata", "--format-version", "1", "--locked", "--offline",
                                         "--filter-platform", "aarch64-apple-darwin"])
            self.assertEqual(kwargs["cwd"], self.root / "Transport")
            self.assertEqual(kwargs["env"]["CARGO_HOME"], str(self.root / "Transport/.cargo-home"))
            kwargs["stdout"].write(json.dumps(self.metadata).encode())
            return subprocess.CompletedProcess(arguments, 0)
        with patch.object(notices.subprocess, "run", side_effect=cargo):
            self.assertEqual(notices.cargo_metadata(self.root), self.metadata)

    def test_normal_and_build_graph_excludes_development_and_unreachable_target_packages(self):
        value = notices.validate(self.generated(), "0.2.0")
        cargo = [c["name"] for c in value["components"] if c["kind"] == "cargo"]
        self.assertEqual(cargo, ["build-helper", "ordinary", "shared"])
        self.assertNotIn("dev-only", cargo)
        self.assertNotIn("wrong-target", cargo)

    def test_generation_is_deterministic_and_never_serializes_private_cache_paths(self):
        duplicate = self.add_package("another-source")
        duplicate.joinpath("LICENSE-MIT").write_bytes(Path(self.package()["manifest_path"]).with_name("LICENSE-MIT").read_bytes())
        self.package("another-source").update(name="ordinary", license="Apache-2.0")
        self.edge("root", "another-source", None)
        first = self.generated()
        reordered = copy.deepcopy(self.metadata)
        reordered["packages"].reverse()
        reordered["resolve"]["nodes"].reverse()
        for node in reordered["resolve"]["nodes"]:
            node["deps"].reverse()
        self.assertEqual(self.generated(reordered), first)
        self.assertNotIn(str(self.root).encode(), first)
        self.assertNotIn(b"manifest_path", first)
        self.assertIn(b"all trailing terms", first)

    def test_all_complete_license_notice_names_and_explicit_file_are_included(self):
        package = self.package()
        root = Path(package["manifest_path"]).parent
        names = ["LICENCE", "COPYING.more", "NOTICE.txt", "UNLICENSE", "nested/LICENSE-extra", "legal/custom.txt"]
        for name in names:
            path = root / name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes((name + " complete terms\n").encode())
        package["license_file"] = str(root / "legal/custom.txt")
        files = notices.package_files(package)
        self.assertEqual({name for name, _ in files}, set(names + ["LICENSE-MIT"]))
        for name, data in files:
            self.assertEqual(data, (root / name).read_bytes())
            self.assertFalse(Path(name).is_absolute())

    def test_missing_binary_empty_oversized_or_symlink_license_fails_closed(self):
        root = Path(self.package()["manifest_path"]).parent
        path = root / "LICENSE-MIT"
        for bad in (None, b"", b" \n", b"\xff", b"binary\0data", b"x" * (notices.MAX_FILE + 1)):
            with self.subTest(bad=None if bad is None else len(bad)):
                if bad is None:
                    path.unlink()
                else:
                    path.write_bytes(bad)
                with self.assertRaises(notices.NoticesError):
                    self.generated()
                path.write_text("Complete restored license.\n")
        path.unlink()
        path.symlink_to(self.root / "LICENSE")
        with self.assertRaises(notices.NoticesError):
            self.generated()
        path.unlink()
        os.mkfifo(path)
        with self.assertRaises(notices.NoticesError):
            self.generated()

    def test_explicit_license_traversal_outside_absolute_path_and_parent_symlink_are_rejected(self):
        package = self.package()
        root = Path(package["manifest_path"]).parent
        for invalid in ("../foreign.txt", str(self.root / "LICENSE")):
            with self.subTest(invalid=invalid), self.assertRaises(notices.NoticesError):
                package["license_file"] = invalid
                self.generated()
        (root / "linked").symlink_to(self.root, target_is_directory=True)
        package["license_file"] = "linked/LICENSE"
        with self.assertRaises(notices.NoticesError):
            self.generated()

    def test_missing_sparkle_license_and_incomplete_cargo_resolution_are_rejected(self):
        path = self.sparkle / "LICENSE"
        path.unlink()
        with self.assertRaises(notices.NoticesError):
            self.generated()
        path.write_text("Sparkle restored license.\n")
        for invalid in (dict(self.metadata, resolve=dict(root=None, nodes=self.nodes)),
                        dict(self.metadata, resolve=dict(root="root", nodes=self.nodes[:-1]))):
            if invalid["resolve"]["root"] is not None:
                invalid["resolve"]["nodes"] = [n for n in self.nodes if n["id"] != "ordinary"]
            with self.assertRaises(notices.NoticesError):
                self.generated(invalid)

    def test_bundle_verification_requires_both_matching_complete_versioned_copies(self):
        app = self.root / "MyDrive.app"
        data = self.generated()
        for bundle in (app, app / notices.PROVIDER):
            path = bundle / notices.RESOURCE
            path.parent.mkdir(parents=True)
            path.write_bytes(data)
        self.assertEqual(notices.verify_bundle(app, "0.2.0")["app_version"], "0.2.0")
        with self.assertRaises(notices.NoticesError):
            notices.verify_bundle(app, "0.2.1")
        (app / notices.PROVIDER / notices.RESOURCE).write_bytes(data[:-1])
        with self.assertRaises(notices.NoticesError):
            notices.verify_bundle(app, "0.2.0")
        with self.assertRaises(notices.NoticesError):
            notices.validate(data[:-1], "0.2.0")


if __name__ == "__main__":
    unittest.main()
