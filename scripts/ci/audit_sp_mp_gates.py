"""Read-only inventory of SP/MP gates in the tracked MK1212 Lua sources.

Run from the repository root:
    python scripts/ci/audit_sp_mp_gates.py
    python scripts/ci/audit_sp_mp_gates.py --json
This is candidate discovery, NOT an automatic proof of safety or completeness.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIRS = ("campaigns/main_attila", "lua_scripts")
NEEDLES = (
    "is_multiplayer(",
    "sp_grand_campaign",
    "mp_grand_campaign",
    "SBOOL_IRONMAN_ENABLED",
    "SBOOL_LUCKY_NATIONS_ENABLED",
    "SBOOL_challenge_",
)


def inventory(root: Path = ROOT) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    for subdir in SOURCE_DIRS:
        for path in sorted((root / subdir).rglob("*.lua")):
            content = path.read_text(encoding="utf-8-sig")
            for number, line in enumerate(content.splitlines(), start=1):
                if any(needle in line for needle in NEEDLES):
                    results.append({
                        "path": path.relative_to(root).as_posix(),
                        "line": number,
                        "code": line.strip()[:240],
                    })
    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args()
    hits = inventory()
    if args.json:
        print(json.dumps({"schema": 1, "candidate_gates": hits}, indent=2))
    else:
        print("SP/MP candidate gates (manual review required):", len(hits))
        for hit in hits:
            print(f"{hit['path']}:{hit['line']}: {hit['code']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
