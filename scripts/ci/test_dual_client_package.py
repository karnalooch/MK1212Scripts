from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

from build_dual_client_lab import PACKAGE_FILES, build_package, package_bytes


class PackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.files = {destination: f"fixture:{source}\n".encode() for source, destination in PACKAGE_FILES}

    def test_archive_is_reproducible_allowlisted_and_self_describing(self) -> None:
        sha = "a" * 40
        data, manifest_data = package_bytes(self.files, sha)
        self.assertEqual((data, manifest_data), package_bytes(dict(reversed(list(self.files.items()))), sha))
        manifest = json.loads(manifest_data)
        self.assertEqual(manifest["source_sha"], sha)
        self.assertEqual(manifest["schema"], 1)
        self.assertEqual(manifest["runtime_evidence"], "NOT_RUN")
        self.assertFalse(manifest["includes_game_assets"])
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            self.assertEqual(set(archive.namelist()), set(self.files) | {"package_manifest.json"})
            for item in manifest["files"]:
                content = archive.read(item["path"])
                self.assertEqual(item["bytes"], len(content))
                self.assertEqual(item["sha256"], hashlib.sha256(content).hexdigest())
            self.assertEqual(archive.read("package_manifest.json"), manifest_data)

    def test_extra_missing_and_invalid_identity_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            package_bytes({**self.files, "Steam/config/loginusers.vdf": b"private"}, "a" * 40)
        missing = dict(self.files)
        missing.pop(next(iter(missing)))
        with self.assertRaises(ValueError):
            package_bytes(missing, "a" * 40)
        for sha in ("", "main", "a" * 7, "G" * 40, "a" * 39 + "\n"):
            with self.subTest(sha=sha), self.assertRaises(ValueError):
                package_bytes(self.files, sha)

    def test_git_build_rejects_dirty_input_wrong_head_and_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "repo"
            root.mkdir()

            def run(*args: str) -> str:
                return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE).decode().strip()

            run("init", "--quiet")
            run("config", "user.email", "fixture@example.invalid")
            run("config", "user.name", "Package fixture")
            run("config", "core.autocrlf", "false")
            for source, destination in PACKAGE_FILES:
                path = root / source
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(self.files[destination])
            # A file outside the allowlist must never be distributed.
            (root / "private.save").write_bytes(b"not package input")
            run("add", ".")
            run("commit", "--quiet", "-m", "fixture")
            sha = run("rev-parse", "HEAD")
            output = Path(temp) / "packages"
            archive = build_package(root, output, sha)
            original = archive.read_bytes()
            with self.assertRaises(FileExistsError):
                build_package(root, output, sha)
            self.assertEqual(archive.read_bytes(), original)
            with self.assertRaises(ValueError):
                build_package(root, output, "0" * 40)
            first = root / PACKAGE_FILES[0][0]
            first.write_bytes(b"uncommitted change")
            with self.assertRaises(subprocess.CalledProcessError):
                build_package(root, Path(temp) / "other", sha)
            self.assertFalse((Path(temp) / "other").exists())


if __name__ == "__main__":
    unittest.main()
