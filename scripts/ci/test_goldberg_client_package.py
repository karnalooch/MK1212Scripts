from __future__ import annotations

import copy
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zipfile

from build_goldberg_client_lab import (
    ARCHIVE_PATH, LOCK_PATH, PACKAGE_FILES, build_package, fetch_archive,
    package_bytes, read_lock, verify_upstream,
)


def identity(data: bytes) -> dict:
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def upstream_fixture(machine: int = 332, extra: str | None = None) -> tuple[bytes, dict]:
    dll = bytearray(256)
    dll[:2] = b"MZ"
    struct.pack_into("<I", dll, 0x3C, 64)
    dll[64:68] = b"PE\0\0"
    struct.pack_into("<H", dll, 68, machine)
    struct.pack_into("<H", dll, 88, 0x10B)
    source = b"fixture source bundle: packaging test only, never a game/runtime input\n"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("steam_api.dll", dll)
        archive.writestr("source_code/source_code.bundle", source)
        archive.writestr("Readme.txt", b"fixture notices\n")
        if extra is not None:
            archive.writestr(extra, b"not allowed")
    data = buffer.getvalue()
    lock = {
        "schema": 1,
        "name": "synthetic packaging fixture",
        "license": "LGPL-3.0-or-later",
        "source_repository": "https://gitlab.com/Mr_Goldberg/goldberg_emulator",
        "source_commit": "4" * 40,
        "archive": {"path": ARCHIVE_PATH, "download_url": "https://gitlab.com/Mr_Goldberg/goldberg_emulator/-/jobs/4247811310/artifacts/download", **identity(data)},
        "dll": {"entry": "steam_api.dll", "machine": 332, **identity(dll)},
        "source_bundle": {"entry": "source_code/source_code.bundle", **identity(source)},
    }
    return data, lock


class GoldbergPackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.upstream, self.lock = upstream_fixture()
        self.files = {destination: f"fixture:{source}\n".encode() for source, destination in PACKAGE_FILES}
        self.files[LOCK_PATH] = json.dumps(self.lock).encode()

    def test_archive_reproducible_with_complete_source_and_provenance(self) -> None:
        result = package_bytes(self.files, "a" * 40, self.upstream)
        self.assertEqual(result, package_bytes(dict(reversed(list(self.files.items()))), "a" * 40, self.upstream))
        data, manifest_data = result
        manifest = json.loads(manifest_data)
        self.assertEqual(manifest["source_sha"], "a" * 40)
        self.assertEqual(manifest["upstream_source_commit"], self.lock["source_commit"])
        self.assertEqual(manifest["runtime_evidence"], "NOT_RUN")
        self.assertEqual(manifest["backend"], "goldberg-emulated-lan")
        self.assertFalse(manifest["includes_game_assets"])
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            self.assertEqual(set(archive.namelist()), set(self.files) | {ARCHIVE_PATH, "package_manifest.json"})
            self.assertEqual(archive.read(ARCHIVE_PATH), self.upstream)
            for item in manifest["files"]:
                content = archive.read(item["path"])
                self.assertEqual(identity(content), {key: item[key] for key in ("bytes", "sha256")})
                if item["path"] == ARCHIVE_PATH:
                    self.assertEqual(item["source_path"], self.lock["archive"]["download_url"])

    def test_missing_extra_assets_wrong_hash_and_identity_are_rejected(self) -> None:
        for files in ({**self.files, "Attila.exe": b"game"}, {k: v for k, v in self.files.items() if k != LOCK_PATH}):
            with self.assertRaises(ValueError):
                package_bytes(files, "a" * 40, self.upstream)
        for sha in ("master", "a" * 7, "G" * 40, "a" * 39 + "\n"):
            with self.subTest(sha=sha), self.assertRaises(ValueError):
                package_bytes(self.files, sha, self.upstream)
        altered = bytearray(self.upstream)
        altered[40] ^= 1
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            package_bytes(self.files, "a" * 40, bytes(altered))
        changed = copy.deepcopy(self.lock)
        changed["source_bundle"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            verify_upstream(self.upstream, changed)

    def test_pe_wrong_architecture_and_unsafe_entries_are_rejected(self) -> None:
        bad, lock = upstream_fixture(machine=34404)
        with self.assertRaisesRegex(ValueError, "not x86"):
            verify_upstream(bad, lock)
        for name in ("../escape.dll", "/absolute.dll", "C:/escape.dll", "nested\\escape.dll"):
            bad, lock = upstream_fixture(extra=name)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "unsafe entry"):
                verify_upstream(bad, lock)

    def test_lock_bounds_and_existing_cache_preservation(self) -> None:
        for field, value in (("download_url", "https://example.invalid/latest.zip"), ("path", "../game.zip"), ("bytes", 50 * 1024 * 1024), ("sha256", "bad")):
            changed = copy.deepcopy(self.lock)
            changed["archive"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                read_lock(json.dumps(changed).encode())
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "archive.zip"
            path.write_bytes(self.upstream)
            self.assertEqual(fetch_archive(path, self.lock), self.upstream)
            damaged = bytearray(self.upstream)
            damaged[-2] ^= 1
            path.write_bytes(damaged)
            with self.assertRaises(ValueError):
                fetch_archive(path, self.lock)
            self.assertEqual(path.read_bytes(), damaged)

    def test_exact_git_head_clean_inputs_and_exclusive_output(self) -> None:
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
            (root / "private.save").write_bytes(b"not package input")
            run("add", ".")
            run("commit", "--quiet", "-m", "fixture")
            sha = run("rev-parse", "HEAD")
            cache = Path(temp) / "upstream.zip"
            cache.write_bytes(self.upstream)
            output = Path(temp) / "packages"
            archive = build_package(root, output, sha, cache)
            original = archive.read_bytes()
            with self.assertRaises(FileExistsError):
                build_package(root, output, sha, cache)
            self.assertEqual(archive.read_bytes(), original)
            with self.assertRaises(ValueError):
                build_package(root, output, "0" * 40, cache)
            (root / PACKAGE_FILES[0][0]).write_bytes(b"uncommitted change")
            with self.assertRaises(subprocess.CalledProcessError):
                build_package(root, Path(temp) / "other", sha, cache)
            self.assertFalse((Path(temp) / "other").exists())


if __name__ == "__main__":
    unittest.main()
