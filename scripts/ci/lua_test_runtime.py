"""Execute production Lua with the repository's vendored Lua 5.1 sources.

This is a scripting compatibility harness, not an Attila engine or MP proof.
The standalone interpreter is built once per Python process in temporary space;
no downloaded dependency or silently skipped test is allowed.
"""
from __future__ import annotations

import atexit
from functools import lru_cache
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
LUA_SOURCE = ROOT / "native/twdll/docs/lua/lua_source/src"
_BUILD_DIRECTORY: tempfile.TemporaryDirectory[str] | None = None


@lru_cache(maxsize=1)
def lua_executable() -> Path:
    """Build the committed interpreter or fail with an actionable error."""
    global _BUILD_DIRECTORY
    compiler = shutil.which("cc") or shutil.which("gcc")
    if compiler is None:
        raise RuntimeError("Lua source tests require a C compiler (cc or gcc); tests were not run")
    _BUILD_DIRECTORY = tempfile.TemporaryDirectory(prefix="mk1212-lua51-")
    atexit.register(_BUILD_DIRECTORY.cleanup)
    binary = Path(_BUILD_DIRECTORY.name) / "lua51"
    # luac.c / print.c belong to the bytecode compiler, not the interpreter.
    sources = sorted(p for p in LUA_SOURCE.glob("*.c") if p.name not in {"luac.c", "print.c"})
    if not sources or not (LUA_SOURCE / "lua.c").is_file():
        raise RuntimeError(f"Vendored Lua interpreter sources are missing: {LUA_SOURCE}")
    subprocess.run(
        [compiler, "-O1", "-DLUA_USE_POSIX", "-DLUA_USE_DLOPEN", "-I", str(LUA_SOURCE),
         *map(str, sources), "-lm", "-ldl", "-o", str(binary)],
        cwd=ROOT, text=True, capture_output=True, check=True, timeout=90,
    )
    return binary


def run_lua_fixture(
    fixture: str | Path, *arguments: str, timeout: int = 30
) -> subprocess.CompletedProcess[str]:
    """Run a fixture from repo root; an assertion failure fails the Python test."""
    path = Path(fixture)
    if not path.is_absolute():
        path = ROOT / path
    result = subprocess.run(
        [str(lua_executable()), str(path), *arguments], cwd=ROOT,
        text=True, capture_output=True, timeout=timeout,
    )
    if result.returncode:
        raise AssertionError(
            f"Lua fixture {path.name} failed (exit {result.returncode})\n"
            f"{result.stdout}{result.stderr}"
        )
    return result
