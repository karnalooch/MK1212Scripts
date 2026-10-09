#!/usr/bin/env python3
"""Exercise the actual pinned Goldberg Git-bundle source in a throwaway directory."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

REPO=Path(__file__).resolve().parents[2]
PATCH=REPO/"scripts/diagnostics/patch_goldberg_steamworks_trace.py"
SHA="aa751fbc421cab0da4ad4edd2e5080d304cfb32794f92430db8a4cb0f291efbf"

def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True).stdout.strip()

def main():
    arc=os.environ.get("GOLDBERG_ARCHIVE_PATH")
    if not arc or not Path(arc).is_file():
        raise SystemExit("Pinned upstream archive GOLDBERG_ARCHIVE_PATH required")
    spec=importlib.util.spec_from_file_location("goldberg_trace_patch",PATCH)
    mod=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    temp_root=REPO/"build"/"goldberg-trace-fixture"
    temp_root.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(dir=temp_root) as d:
        d=Path(d)
        bundle=d/"source_code.bundle"
        with zipfile.ZipFile(arc) as f:
            data=f.read("source_code/source_code.bundle")
        assert hashlib.sha256(data).hexdigest()==SHA, "Git bundle hash mismatch"
        bundle.write_bytes(data)
        source=d/"original"
        run("git","clone","--quiet",str(bundle),str(source))
        run("git","checkout","--detach",mod.UPSTREAM_COMMIT,cwd=source)
        assert run("git","rev-parse","HEAD",cwd=source)==mod.UPSTREAM_COMMIT
        original={rel:hashlib.sha256((source/rel).read_bytes()).hexdigest() for rel in mod.PATCHERS}
        result=mod.prepare(source,d/"instrumented")
        assert result["source_commit"]==mod.UPSTREAM_COMMIT
        assert (d/"instrumented/dll/mk1212_steamworks_trace.h").is_file()
        for rel in mod.PATCHERS:
            assert hashlib.sha256((source/rel).read_bytes()).hexdigest()==original[rel]
            assert (d/"instrumented"/rel).read_bytes()!=(source/rel).read_bytes()
        for name in ("CreateLobby.call","LobbyCreated.callback","LobbyMatchList.callback","RequestLANServerList.call","ServerList.callback","InviteUserToGame.call"):
            assert any(name in (d/"instrumented"/rel).read_text(encoding="utf-8") for rel in mod.PATCHERS),name
        try:
            mod.prepare(source,d/"instrumented")
            raise AssertionError("Must refuse existing output")
        except RuntimeError as e:
            assert "existing output" in str(e)
        tampered=d/"tampered"
        shutil.copytree(source,tampered,ignore=shutil.ignore_patterns(".git"))
        with (tampered/"dll/steam_matchmaking.h").open("a",encoding="utf-8") as f: f.write("\n// tampered\n")
        try:
            mod.prepare(tampered,d/"refused")
            raise AssertionError("Must refuse tampered upstream source")
        except RuntimeError as e:
            assert "Unpinned" in str(e)
        assert not (d/"refused").exists()
    print("PASS: pinned Goldberg source instrumentation, callsites, source immutability, fail-closed refusal")
if __name__=="__main__":main()
