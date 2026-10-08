"""Compile a real Windows wizard from an exact-source verified Goldberg package.

Windows uses the hash-pinned original NSIS ZIP. Linux accepts the native compiler
built from the matching pinned sources and the original Windows stubs/plugins.
The installer never contains ATTILA or Workshop assets.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import struct
import subprocess
import urllib.request
import zipfile

from build_dual_client_lab import git
from build_goldberg_client_lab import ARCHIVE_PATH, committed_files, package_bytes

ROOT = Path(__file__).resolve().parents[2]
BUILD_INPUTS = (
    "scripts/installer/goldberg_lab.nsi",
    "scripts/ci/build_goldberg_installer.py",
    "third_party/nsis/lock.json",
)
MAX_PACKAGE_BYTES = 48 * 1024 * 1024


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_nsis_lock(data: bytes) -> dict:
    if len(data) > 32768:
        raise ValueError("NSIS lock exceeds the size bound")
    lock = json.loads(data)
    if lock.get("schema") != 1 or lock.get("version") != "3.13":
        raise ValueError("Unsupported NSIS build lock")
    if lock.get("windows_compiler") != "nsis-3.13/makensis.exe":
        raise ValueError("Unexpected NSIS compiler path")
    for field, suffix in (("archive", ".zip"), ("source", "-src.tar.bz2")):
        item = lock[field]
        expected_url = f"https://downloads.sourceforge.net/project/nsis/NSIS%203/3.13/nsis-3.13{suffix}"
        if item.get("url") != expected_url:
            raise ValueError("NSIS dependency must use the pinned official release")
        if type(item.get("bytes")) is not int or not 1 <= item["bytes"] <= 10 * 1024 * 1024:
            raise ValueError("Invalid NSIS dependency size")
        if len(item.get("sha256", "")) != 64 or any(c not in "0123456789abcdef" for c in item["sha256"]):
            raise ValueError("Invalid NSIS dependency digest")
    return lock


def verified_package(root: Path, source_sha: str, package_path: Path) -> tuple[dict[str, bytes], bytes]:
    files = committed_files(root, source_sha)
    if package_path.is_symlink() or package_path.stat().st_size > MAX_PACKAGE_BYTES:
        raise ValueError("Package path/size is outside the installer bound")
    data = package_path.read_bytes()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        info = archive.getinfo(ARCHIVE_PATH)
        if info.file_size > 40 * 1024 * 1024:
            raise ValueError("Bundled upstream archive exceeds the size bound")
        upstream = archive.read(info)
    expected, manifest = package_bytes(files, source_sha, upstream)
    if expected != data:
        raise ValueError("Installer input is not the exact-source reproducible package")
    return {**files, ARCHIVE_PATH: upstream, "package_manifest.json": manifest}, data


def fetch_nsis(path: Path, lock: dict) -> bytes:
    identity = lock["archive"]
    if path.is_symlink():
        raise ValueError("NSIS cache must not be a symlink")
    if path.exists():
        if path.stat().st_size != identity["bytes"]:
            raise ValueError("Existing NSIS cache has changed; it was preserved")
        data = path.read_bytes()
    else:
        request = urllib.request.Request(identity["url"], headers={"User-Agent": "MK1212-installer-builder/1"})
        with urllib.request.urlopen(request, timeout=60) as response:
            if not response.url.startswith("https://"):
                raise ValueError("Refusing non-HTTPS NSIS redirect")
            data = response.read(identity["bytes"] + 1)
        if len(data) != identity["bytes"] or digest(data) != identity["sha256"]:
            raise ValueError("NSIS release archive size/SHA-256 mismatch")
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as output:
            output.write(data)
    if len(data) != identity["bytes"] or digest(data) != identity["sha256"]:
        raise ValueError("NSIS release archive size/SHA-256 mismatch")
    return data


def extract_nsis(data: bytes, destination: Path) -> Path:
    # An exclusive private directory prevents an existing altered plug-in/stub
    # from being accepted as a member of the verified upstream distribution.
    destination.mkdir()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if len(entries) > 2048 or sum(item.file_size for item in entries) > 64 * 1024 * 1024:
            raise ValueError("NSIS archive exceeds extraction bounds")
        names: set[str] = set()
        for item in entries:
            path = PurePosixPath(item.filename)
            key = item.filename.casefold()
            if (path.is_absolute() or ".." in path.parts or "\\" in item.filename or ":" in item.filename
                    or not path.parts or path.parts[0] != "nsis-3.13" or key in names):
                raise ValueError("NSIS archive contains an unsafe or duplicate path")
            names.add(key)
            mode = item.external_attr >> 16
            if mode & 0o170000 == 0o120000:
                raise ValueError("NSIS archive must not contain symlinks")
        archive.extractall(destination)
    return destination / "nsis-3.13"


def nsis_string(value: str) -> str:
    if any(c in value for c in "\r\n\0"):
        raise ValueError("Control character in NSIS compile-time path")
    return value.replace("$", "$$").replace('"', '$\\"')


def payload_include(files: dict[str, bytes], payload: Path) -> str:
    lines: list[str] = []
    for relative in sorted(files):
        path = PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts or "\\" in relative or ":" in relative:
            raise ValueError("Unsafe installer payload name")
        parent = str(path.parent).replace("/", "\\")
        destination = "$PLUGINSDIR\\payload" + ("" if parent == "." else "\\" + parent)
        lines.append(f'SetOutPath "{destination}"')
        lines.append(f'File "/oname={path.name}" "{nsis_string(str(payload / relative))}"')
    return "\n".join(lines) + "\n"


def verify_installer_pe(data: bytes) -> None:
    if len(data) < 4096 or len(data) > MAX_PACKAGE_BYTES or data[:2] != b"MZ":
        raise ValueError("Installer is not a bounded Windows PE image")
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    if offset + 26 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        raise ValueError("Installer PE header is invalid")
    if struct.unpack_from("<H", data, offset + 4)[0] != 332:
        raise ValueError("Expected the pinned Unicode x86 NSIS runtime")
    if b'asInvoker' not in data:
        raise ValueError("Installer does not declare the required current-user privilege level")


def build_installer(root: Path, source_sha: str, package_path: Path, output_dir: Path,
                    nsis_archive: Path, native_compiler: Path | None = None) -> Path:
    files, package = verified_package(root, source_sha, package_path)
    git(root, "diff", "--exit-code", source_sha, "--", *BUILD_INPUTS)
    inputs = {path: git(root, "show", f"{source_sha}:{path}") for path in BUILD_INPUTS}
    lock = read_nsis_lock(inputs["third_party/nsis/lock.json"])
    nsis_zip = fetch_nsis(nsis_archive, lock)
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / source_sha
    destination.mkdir()
    payload = destination / "payload"
    payload.mkdir()
    for name, data in files.items():
        path = payload / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("xb") as output:
            output.write(data)
        os.utime(path, (315532800, 315532800))
    nsis_root = extract_nsis(nsis_zip, destination / "compiler")
    if os.name == "nt":
        if native_compiler is not None:
            raise ValueError("Windows builds must use the verified upstream compiler")
        compiler = nsis_root / "makensis.exe"
        option = "/"
    else:
        if native_compiler is None or not native_compiler.is_file():
            raise ValueError("Linux builds require --makensis from the pinned NSIS source archive")
        compiler = native_compiler.resolve()
        option = "-"
    environment = os.environ.copy()
    environment["NSISDIR"] = str(nsis_root)
    environment["SOURCE_DATE_EPOCH"] = "1790467200"
    version = subprocess.check_output([str(compiler), option + "VERSION"], env=environment).decode().strip()
    if version != "v" + lock["version"]:
        raise ValueError(f"Unexpected compiler version: {version}")
    script = destination / "goldberg_lab.nsi"
    script.write_bytes(inputs["scripts/installer/goldberg_lab.nsi"])
    include = destination / "payload.nsh"
    include.write_text(payload_include(files, payload), encoding="utf-8")
    installer = destination / f"MK1212-Setup-{source_sha[:12]}.exe"
    command = [
        str(compiler), option + "NOCONFIG", option + "V3",
        option + "DPAYLOAD=" + str(payload),
        option + "DPAYLOAD_INCLUDE=" + str(include),
        option + "DOUTPUT=" + str(installer),
        option + "DSOURCE_SHA=" + source_sha,
        str(script),
    ]
    result = subprocess.run(command, env=environment, cwd=destination, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = result.stdout.decode("utf-8", errors="replace")
    (destination / "compiler.log").write_text(log, encoding="utf-8")
    if result.returncode:
        raise ValueError("NSIS compilation failed:\n" + log[-16000:])
    data = installer.read_bytes()
    verify_installer_pe(data)
    report = {
        "schema": 1, "owner": "MK1212Scripts.goldberg-installer-build",
        "source_sha": source_sha, "source_repository": "https://github.com/karnalooch/MK1212Scripts",
        "installer": {"filename": installer.name, "bytes": len(data), "sha256": digest(data)},
        "package_sha256": digest(package),
        "compiler": {"version": version, "host": os.name, "original_zip_sha256": digest(nsis_zip)},
        "build_inputs": {path: digest(value) for path, value in inputs.items()},
        "runtime_evidence": "NOT_RUN", "includes_game_assets": False,
        "default_host": "C:\\MK1212\\HOST", "default_client": "D:\\MK1212\\CLIENT",
    }
    (destination / "installer-build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (destination / "SHA256SUMS.txt").write_text(f"{digest(data)}  {installer.name}\n", encoding="ascii")
    print(f"Installer: {installer}")
    print(f"Installer SHA256: {digest(data)}")
    print(f"Source SHA: {source_sha}; NSIS {version}; Windows ATTILA multiplayer: NOT_RUN")
    return installer


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build" / "goldberg-installer")
    parser.add_argument("--nsis-archive", type=Path, default=ROOT / "build" / "nsis-3.13.zip")
    parser.add_argument("--makensis", type=Path)
    args = parser.parse_args()
    try:
        build_installer(args.source_root.resolve(), args.source_sha, args.package.resolve(),
                        args.output_dir.resolve(), args.nsis_archive.resolve(), args.makensis)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Installer build failed: {exc}\n")


if __name__ == "__main__":
    main()
