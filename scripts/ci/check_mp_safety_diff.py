from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNTIME_PATHS = ("campaigns", "lua_scripts", "script")

FATAL_PATTERNS = {
    "lua math.random": re.compile(r"\bmath\.random\s*\("),
    "lua math.randomseed": re.compile(r"\bmath\.randomseed\b"),
    "wall clock os.time": re.compile(r"\bos\.time\b"),
    "process clock os.clock": re.compile(r"\bos\.clock\b"),
}

ADVISORY_PATTERNS = {
    "unordered pairs iteration": re.compile(r"\bpairs\s*\("),
    "time trigger": re.compile(r"\bcm:add_time_trigger\s*\("),
    "force creation": re.compile(r"\bcm:create_force\s*\("),
    "character spawn": re.compile(r"\b(?:cm:)?spawn_character"),
    "dynamic UI component": re.compile(r"\bCreateComponent\s*\("),
    "local UI/selection event": re.compile(r'"(?:ComponentLClickUp|CharacterSelected|SettlementSelected|PanelOpenedCampaign|PanelClosedCampaign)"'),
    "building health mutation": re.compile(r"\binstant_set_building_health_percent\s*\("),
    "forced diplomacy": re.compile(r"\bforce_declare_war\s*\("),
    "dilemma or incident": re.compile(r"\btrigger_(?:dilemma|incident)\s*\("),
}


def run(*args: str) -> str:
    proc = subprocess.run(
        args,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def resolve_base(candidate: str | None) -> str | None:
    if candidate and candidate.strip("0"):
        return candidate
    try:
        return run("git", "rev-parse", "HEAD^").strip()
    except RuntimeError:
        return None


def added_lines(base: str) -> list[tuple[str, str]]:
    diff = run(
        "git",
        "diff",
        "--unified=0",
        f"{base}...HEAD",
        "--",
        *RUNTIME_PATHS,
    )
    current_path = ""
    result: list[tuple[str, str]] = []
    for raw in diff.splitlines():
        if raw.startswith("+++ b/"):
            current_path = raw[6:]
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            result.append((current_path, raw[1:]))
    return result


def lua_code_only(line: str) -> str:
    # High-confidence diff guard: ignore ordinary single-line Lua comments.
    # This is intentionally conservative and is not a Lua parser.
    return line.split("--", 1)[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=None)
    args = parser.parse_args()

    base = resolve_base(args.base)
    if not base:
        print("mp safety diff guard: PASS (no comparable base ref)")
        return 0

    try:
        lines = added_lines(base)
    except RuntimeError as exc:
        print(f"mp safety diff guard: FAIL: {exc}", file=sys.stderr)
        return 1

    fatal: list[str] = []
    advisory: list[str] = []

    for path, line in lines:
        code = lua_code_only(line)
        if not code.strip():
            continue

        for name, pattern in FATAL_PATTERNS.items():
            if pattern.search(code):
                fatal.append(f"{path}: {name}: {line.strip()}")

        for name, pattern in ADVISORY_PATTERNS.items():
            if pattern.search(code):
                advisory.append(f"{path}: {name}: {line.strip()}")

    if advisory:
        print("mp safety diff guard: REVIEW advisory additions:")
        for item in advisory:
            print(f"  - {item}")

    if fatal:
        print("mp safety diff guard: FAIL: new nondeterministic runtime source(s)", file=sys.stderr)
        for item in fatal:
            print(f"  - {item}", file=sys.stderr)
        print(
            "Use an Attila-MP deterministic mechanism proven by exact-build evidence; "
            "do not bypass this guard with local entropy.",
            file=sys.stderr,
        )
        return 1

    print(
        "mp safety diff guard: PASS "
        f"({len(lines)} added runtime line(s), {len(advisory)} advisory review item(s))"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
