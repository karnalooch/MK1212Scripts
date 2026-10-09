"""Build a small, reproducible toolkit from exact committed Git blobs.

Only the explicit allowlist below is distributed. No game, native DLL, profile,
save, Steam file, or runtime evidence is an input to this builder.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parents[2]
PACKAGE_FILES = (
    ("docs/research/DUAL_CLIENT_LAB.md", "README.md"),
    ("scripts/runtime/RUN-DUAL-CLIENT-LAB.cmd", "RUN-DUAL-CLIENT-LAB.cmd"),
    ("scripts/runtime/dual_client_lab.ps1", "scripts/runtime/dual_client_lab.ps1"),
    ("scripts/runtime/dual_client_lab_core.psm1", "scripts/runtime/dual_client_lab_core.psm1"),
    ("scripts/runtime/dual_client_probe.ps1", "scripts/runtime/dual_client_probe.ps1"),
)


def git(root: Path, *arguments: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout


def committed_files(root: Path, source_sha: str) -> dict[str, bytes]:
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("source_sha must be a complete lowercase 40-character Git SHA")
    actual = git(root, "rev-parse", "HEAD").decode("ascii").strip()
    if actual != source_sha:
        raise ValueError(f"Expected exact checkout {source_sha}, found {actual}")
    # Detect staged/unstaged changes to the input files. The package itself uses
    # Git blobs, so Windows checkout newline conversion cannot change its bytes.
    git(root, "diff", "--exit-code", source_sha, "--", *(item[0] for item in PACKAGE_FILES))
    return {
        destination: git(root, "show", f"{source_sha}:{source}")
        for source, destination in PACKAGE_FILES
    }


def package_bytes(files: dict[str, bytes], source_sha: str) -> tuple[bytes, bytes]:
    expected = {destination for _, destination in PACKAGE_FILES}
    if set(files) != expected:
        raise ValueError("Package inputs differ from the fixed toolkit allowlist")
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("Invalid package source_sha")
    sources = {destination: source for source, destination in PACKAGE_FILES}
    manifest = {
        "schema": 1,
        "package": "mk1212-dual-client-lab",
        "source_repository": "https://github.com/karnalooch/MK1212Scripts",
        "source_sha": source_sha,
        "experimental": True,
        "runtime_evidence": "NOT_RUN",
        "includes_game_assets": False,
        "files": [
            {
                "path": path,
                "source_path": sources[path],
                "bytes": len(files[path]),
                "sha256": hashlib.sha256(files[path]).hexdigest(),
            }
            for path in sorted(files)
        ],
    }
    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    entries = {**files, "package_manifest.json": manifest_bytes}
    buffer = io.BytesIO()
    # ZIP_STORED avoids zlib/version-dependent output; the whole toolkit is small.
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    data = buffer.getvalue()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != set(entries):
            raise ValueError("Built archive failed its content/integrity check")
    return data, manifest_bytes


def build_package(root: Path, output_dir: Path, source_sha: str) -> Path:
    data, manifest = package_bytes(committed_files(root, source_sha), source_sha)
    name = f"mk1212-dual-client-lab-{source_sha}"
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / name
    # Exclusive directory ownership preserves previous builds, even on failure.
    destination.mkdir()
    archive = destination / f"{name}.zip"
    partial = destination / f"{name}.zip.partial"
    partial.write_bytes(data)
    (destination / "package_manifest.json").write_bytes(manifest)
    digest = hashlib.sha256(data).hexdigest()
    (destination / "SHA256SUMS.txt").write_text(f"{digest}  {archive.name}\n", encoding="ascii")
    partial.rename(archive)
    print(f"Package: {archive}")
    print(f"Source SHA: {source_sha}")
    print(f"SHA256: {digest}")
    print("Real Steam/Attila runtime: NOT_RUN (separate operator evidence required)")
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build" / "dual-client-lab")
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    try:
        build_package(args.source_root, args.output_dir, args.source_sha)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Package build failed: {exc}\n")


if __name__ == "__main__":
    main()
