from __future__ import annotations

import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from build_goldberg_client_lab import ARCHIVE_PATH, LOCK_PATH, PACKAGE_FILES, package_bytes
from build_goldberg_installer import (
    ROOT, extract_nsis, nsis_string, payload_include, read_nsis_lock, verified_package,
)
from test_goldberg_client_package import upstream_fixture


class GoldbergInstallerPackagingTests(unittest.TestCase):
    def test_only_exact_source_package_is_accepted(self) -> None:
        upstream, lock = upstream_fixture()
        files = {destination: (source + "\n").encode() for source, destination in PACKAGE_FILES}
        files[LOCK_PATH] = json.dumps(lock).encode()
        package, manifest = package_bytes(files, "a" * 40, upstream)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "package.zip"
            path.write_bytes(package)
            with patch("build_goldberg_installer.committed_files", return_value=files):
                entries, actual = verified_package(Path(temporary), "a" * 40, path)
                self.assertEqual(actual, package)
                self.assertEqual(entries["package_manifest.json"], manifest)
                self.assertEqual(entries[ARCHIVE_PATH], upstream)
                # An added file must not become an installer input just because
                # it fits in a structurally valid archive.
                with zipfile.ZipFile(path, "a") as archive:
                    archive.writestr("unrequested.exe", b"unrequested input")
                with self.assertRaisesRegex(ValueError, "exact-source"):
                    verified_package(Path(temporary), "a" * 40, path)

    def test_compiler_pin_cannot_be_redirected_or_unbounded(self) -> None:
        lock = json.loads((ROOT / "third_party/nsis/lock.json").read_bytes())
        self.assertEqual(read_nsis_lock(json.dumps(lock).encode())["version"], "3.13")
        for key, value in (("url", "https://example.invalid/nsis.zip"), ("bytes", 100_000_000), ("sha256", "x" * 64)):
            bad = copy.deepcopy(lock)
            bad["archive"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                read_nsis_lock(json.dumps(bad).encode())
        bad = copy.deepcopy(lock)
        bad["version"] = "latest"
        with self.assertRaises(ValueError):
            read_nsis_lock(json.dumps(bad).encode())

    def test_compiler_extraction_rejects_traversal_links_and_duplicates(self) -> None:
        cases = ("../outside.txt", "/absolute.txt", "nsis-3.13\\escape.txt", "C:/escape.txt", "other/makensis.exe")
        with tempfile.TemporaryDirectory() as temporary:
            for index, name in enumerate(cases):
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, "w") as archive:
                    archive.writestr(name, b"x")
                with self.subTest(name=name), self.assertRaises(ValueError):
                    extract_nsis(buffer.getvalue(), Path(temporary) / str(index))
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                entry = zipfile.ZipInfo("nsis-3.13/link")
                entry.create_system = 3
                entry.external_attr = 0o120777 << 16
                archive.writestr(entry, b"outside")
            with self.assertRaises(ValueError):
                extract_nsis(buffer.getvalue(), Path(temporary) / "link")

    def test_literal_payload_paths_and_fixed_file_enumeration(self) -> None:
        self.assertEqual(nsis_string('folder $value/"file"'), 'folder $$value/$\\"file$\\"')
        for value in ("new\nline", "new\rline", "null\0value"):
            with self.assertRaises(ValueError):
                nsis_string(value)
        result = payload_include({"scripts/run.ps1": b"", "README.md": b""}, Path("path $with spaces"))
        self.assertEqual(result.count("\nFile "), 2)
        self.assertIn('path $$with spaces', result)
        self.assertNotIn("File /r", result)
        with self.assertRaises(ValueError):
            payload_include({"../game.exe": b""}, Path("payload"))


if __name__ == "__main__":
    unittest.main()
