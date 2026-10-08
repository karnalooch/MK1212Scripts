"""Reconstruct two authentic released toolkit payloads for upgrade regression tests.

This helper is test-only: it executes no historical scripts and ships no bypass.
Every payload is reconstructed from exact Git blobs and the pinned upstream ZIP;
its complete manifest must equal the independently recorded release identity.
"""

from __future__ import annotations

import argparse
import hashlib
import io
from pathlib import Path, PurePosixPath
import zipfile

from build_dual_client_lab import git
from build_goldberg_client_lab import ARCHIVE_PATH, PACKAGE_FILES, package_bytes


ROOT = Path(__file__).resolve().parents[2]
RELEASES = {
    "7f66f06afddc53fda220f22d1940242ebd87e4ab":
        "6437e64419ff4337bf43ae2f62976f503e3878571f876ba09a4ec4d4c744f435",
    "f5158fa52138d87ef00fa154b3fb50b636dabc23":
        "58dda3727415324429da1f5eccd11ae9d2674570d6198bda367bb51f3cff5837",
}


def reconstruct(root: Path, source_sha: str, upstream: bytes) -> dict[str, bytes]:
    files = {
        destination: git(root, "show", f"{source_sha}:{source}")
        for source, destination in PACKAGE_FILES
    }
    package, manifest = package_bytes(files, source_sha, upstream)
    if hashlib.sha256(manifest).hexdigest() != RELEASES[source_sha]:
        raise ValueError(f"Reconstructed manifest differs from actual release {source_sha}")
    expected = set(files) | {ARCHIVE_PATH, "package_manifest.json"}
    with zipfile.ZipFile(io.BytesIO(package)) as archive:
        if len(archive.infolist()) != len(expected) or set(archive.namelist()) != expected:
            raise ValueError("Historical fixture differs from the fixed toolkit file set")
        result = {}
        for name in sorted(expected):
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
                raise ValueError("Unsafe historical fixture path")
            result[name] = archive.read(name)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--archive", type=Path, default=ROOT / "build" / "goldberg-upstream.zip")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build" / "goldberg-upgrade-fixtures")
    arguments = parser.parse_args()
    if arguments.archive.is_symlink() or not arguments.archive.is_file():
        raise ValueError("A regular cached upstream archive is required")
    if arguments.archive.stat().st_size > 40 * 1024 * 1024:
        raise ValueError("Upstream archive exceeds its size bound")
    upstream = arguments.archive.read_bytes()
    # Validate both complete payloads before creating any output directory.
    payloads = {
        sha: reconstruct(arguments.source_root, sha, upstream)
        for sha in RELEASES
    }
    for sha in payloads:
        target = arguments.output_dir / sha
        if target.exists() or target.is_symlink():
            raise FileExistsError(f"Fixture output already exists; preserved: {target}")
    for sha, files in payloads.items():
        target = arguments.output_dir / sha
        target.mkdir(parents=True)
        for name, data in files.items():
            destination = target.joinpath(*PurePosixPath(name).parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("xb") as output:
                output.write(data)
        print(f"Verified historical toolkit fixture: {target}; manifest SHA256={RELEASES[sha]}")


if __name__ == "__main__":
    main()
