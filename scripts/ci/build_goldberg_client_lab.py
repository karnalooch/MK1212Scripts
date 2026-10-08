"""Build the exact-source Goldberg lab, including the pinned unmodified upstream ZIP.

No game assets, user profiles, credentials, or operator evidence are package inputs.
The emulator's corresponding source bundle and notices travel in its original ZIP.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import urllib.request
import zipfile

from build_dual_client_lab import git


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = "third_party/goldberg/lock.json"
ARCHIVE_PATH = "third_party/goldberg/goldberg-original-475342f0.zip"
PACKAGE_FILES = (
    ("docs/research/GOLDBERG_DUAL_CLIENT_LAB.md", "README.md"),
    ("scripts/runtime/RUN-GOLDBERG-LAB.cmd", "RUN-GOLDBERG-LAB.cmd"),
    ("scripts/runtime/goldberg_client_lab.ps1", "scripts/runtime/goldberg_client_lab.ps1"),
    ("scripts/runtime/goldberg_client_lab_core.psm1", "scripts/runtime/goldberg_client_lab_core.psm1"),
    ("scripts/runtime/dual_client_lab_core.psm1", "scripts/runtime/dual_client_lab_core.psm1"),
    ("scripts/runtime/dual_client_probe.ps1", "scripts/runtime/dual_client_probe.ps1"),
    (LOCK_PATH, LOCK_PATH),
    ("third_party/goldberg/UPSTREAM.md", "third_party/goldberg/UPSTREAM.md"),
    ("third_party/goldberg/LICENSE.LGPL-3.0.txt", "third_party/goldberg/LICENSE.LGPL-3.0.txt"),
    ("third_party/goldberg/LICENSE.GPL-3.0.txt", "third_party/goldberg/LICENSE.GPL-3.0.txt"),
)


def read_lock(content: bytes) -> dict:
    if len(content) > 32_768:
        raise ValueError("Upstream lock exceeds the size bound")
    lock = json.loads(content)
    if lock.get("schema") != 1 or lock.get("license") != "LGPL-3.0-or-later":
        raise ValueError("Unsupported upstream lock schema/license")
    if lock.get("source_repository") != "https://gitlab.com/Mr_Goldberg/goldberg_emulator":
        raise ValueError("Unexpected upstream source repository")
    if not re.fullmatch(r"[0-9a-f]{40}", lock.get("source_commit", "")):
        raise ValueError("Upstream source commit must be complete")
    archive = lock["archive"]
    if archive.get("path") != ARCHIVE_PATH:
        raise ValueError("Unexpected upstream archive destination")
    if not re.fullmatch(
        r"https://gitlab\.com/Mr_Goldberg/goldberg_emulator/-/jobs/[0-9]+/artifacts/download",
        archive.get("download_url", ""),
    ):
        raise ValueError("Upstream download must be a pinned official GitLab job")
    for field, maximum in (("archive", 40 * 1024 * 1024), ("dll", 8 * 1024 * 1024), ("source_bundle", 20 * 1024 * 1024)):
        item = lock[field]
        if type(item.get("bytes")) is not int or not 1 <= item["bytes"] <= maximum:
            raise ValueError(f"Invalid bounded size for {field}")
        if not re.fullmatch(r"[0-9a-f]{64}", item.get("sha256", "")):
            raise ValueError(f"Invalid SHA-256 for {field}")
    if lock["dll"].get("entry") != "steam_api.dll" or lock["dll"].get("machine") != 332:
        raise ValueError("Only the root PE32 x86 steam_api.dll is selected")
    if lock["source_bundle"].get("entry") != "source_code/source_code.bundle":
        raise ValueError("Corresponding source bundle is required")
    return lock


def check_blob(data: bytes, identity: dict, label: str) -> None:
    if len(data) != identity["bytes"] or hashlib.sha256(data).hexdigest() != identity["sha256"]:
        raise ValueError(f"{label}: pinned size/SHA-256 mismatch")


def verify_upstream(data: bytes, lock: dict) -> None:
    check_blob(data, lock["archive"], "Goldberg archive")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or len(names) > 4096:
            raise ValueError("Upstream ZIP contains duplicate/excessive entries")
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
                raise ValueError("Upstream ZIP contains an unsafe entry name")
        for field in ("dll", "source_bundle"):
            identity = lock[field]
            info = archive.getinfo(identity["entry"])
            if info.file_size != identity["bytes"]:
                raise ValueError(f"{field}: unexpected uncompressed size")
            content = archive.read(info)
            check_blob(content, identity, field)
            if field == "dll":
                if len(content) < 64 or content[:2] != b"MZ":
                    raise ValueError("Selected DLL is not a PE image")
                offset = struct.unpack_from("<I", content, 0x3C)[0]
                if offset + 26 > len(content) or content[offset : offset + 4] != b"PE\0\0":
                    raise ValueError("Selected DLL has an invalid PE header")
                if struct.unpack_from("<H", content, offset + 4)[0] != 332:
                    raise ValueError("Selected DLL is not x86")
                if struct.unpack_from("<H", content, offset + 24)[0] != 0x10B:
                    raise ValueError("Selected DLL is not PE32")
        if "Readme.txt" not in names:
            raise ValueError("Original upstream usage notices are missing")


def committed_files(root: Path, source_sha: str) -> dict[str, bytes]:
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("source_sha must be a complete lowercase 40-character Git SHA")
    actual = git(root, "rev-parse", "HEAD").decode("ascii").strip()
    if actual != source_sha:
        raise ValueError(f"Expected exact checkout {source_sha}, found {actual}")
    git(root, "diff", "--exit-code", source_sha, "--", *(source for source, _ in PACKAGE_FILES))
    return {destination: git(root, "show", f"{source_sha}:{source}") for source, destination in PACKAGE_FILES}


def fetch_archive(path: Path, lock: dict) -> bytes:
    if path.is_symlink():
        raise ValueError("Archive cache must not be a symbolic link")
    if path.exists():
        if path.stat().st_size != lock["archive"]["bytes"]:
            raise ValueError("Existing archive cache has an unexpected size; it is preserved")
        data = path.read_bytes()
    else:
        print("Downloading pinned original Goldberg artifact from its official GitLab job", flush=True)
        request = urllib.request.Request(lock["archive"]["download_url"], headers={"User-Agent": "MK1212-GoldbergLab-builder/1"})
        with urllib.request.urlopen(request, timeout=60) as response:
            if not response.url.startswith("https://"):
                raise ValueError("Refusing a non-HTTPS artifact redirect")
            data = response.read(lock["archive"]["bytes"] + 1)
        verify_upstream(data, lock)
        path.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation preserves a file created concurrently by another build.
        with path.open("xb") as output:
            output.write(data)
    verify_upstream(data, lock)
    print(f"Verified upstream archive: {path}; SHA256={lock['archive']['sha256']}", flush=True)
    return data


def package_bytes(files: dict[str, bytes], source_sha: str, upstream: bytes) -> tuple[bytes, bytes]:
    if set(files) != {destination for _, destination in PACKAGE_FILES}:
        raise ValueError("Package inputs differ from the fixed toolkit allowlist")
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("Invalid package source_sha")
    lock = read_lock(files[LOCK_PATH])
    verify_upstream(upstream, lock)
    entries = {**files, ARCHIVE_PATH: upstream}
    sources = {destination: source for source, destination in PACKAGE_FILES}
    sources[ARCHIVE_PATH] = lock["archive"]["download_url"]
    manifest = {
        "schema": 1,
        "package": "mk1212-goldberg-client-lab",
        "source_repository": "https://github.com/karnalooch/MK1212Scripts",
        "source_sha": source_sha,
        "experimental": True,
        "backend": "goldberg-emulated-lan",
        "runtime_evidence": "NOT_RUN",
        "includes_game_assets": False,
        "upstream_source_commit": lock["source_commit"],
        "files": [
            {"path": path, "source_path": sources[path], "bytes": len(entries[path]), "sha256": hashlib.sha256(entries[path]).hexdigest()}
            for path in sorted(entries)
        ],
    }
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    entries["package_manifest.json"] = manifest_bytes
    buffer = io.BytesIO()
    # Store the already compressed upstream archive and normalize all ZIP metadata.
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, content in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, content)
    data = buffer.getvalue()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != set(entries):
            raise ValueError("Built archive failed its content/integrity check")
    return data, manifest_bytes


def build_package(root: Path, output_dir: Path, source_sha: str, archive_path: Path) -> Path:
    files = committed_files(root, source_sha)
    upstream = fetch_archive(archive_path, read_lock(files[LOCK_PATH]))
    data, manifest = package_bytes(files, source_sha, upstream)
    name = f"mk1212-goldberg-client-lab-{source_sha}"
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / name
    destination.mkdir()
    archive = destination / f"{name}.zip"
    partial = destination / f"{name}.zip.partial"
    partial.write_bytes(data)
    (destination / "package_manifest.json").write_bytes(manifest)
    (destination / "SHA256SUMS.txt").write_text(f"{hashlib.sha256(data).hexdigest()}  {archive.name}\n", encoding="ascii")
    partial.rename(archive)
    print(f"Package: {archive}")
    print(f"Source SHA: {source_sha}")
    print(f"SHA256: {hashlib.sha256(data).hexdigest()}")
    print("Real ATTILA lobby/campaign/turn runtime: NOT_RUN (operator evidence required)")
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build" / "goldberg-client-lab")
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--archive", type=Path, default=ROOT / "build" / "goldberg-upstream.zip")
    parser.add_argument("--fetch-only", action="store_true", help="Verify/download the pinned archive for subsequent Windows contract tests")
    args = parser.parse_args()
    try:
        if args.fetch_only:
            files = committed_files(args.source_root, args.source_sha)
            fetch_archive(args.archive, read_lock(files[LOCK_PATH]))
        else:
            build_package(args.source_root, args.output_dir, args.source_sha, args.archive)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Package build failed: {exc}\n")


if __name__ == "__main__":
    main()
