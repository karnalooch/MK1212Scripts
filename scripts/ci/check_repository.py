from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLATFORM_SHA = "ddc458c223b8020c5f36482415d4405459bd373a"

REQUIRED_DIRS = ("campaigns", "db", "lua_scripts", "script", "text", "ui")
REQUIRED_FILES = (
    "gumball.yaml",
    "AGENTS.md",
    "docs/README.md",
    "docs/ARCHITECTURE.md",
    "docs/GUMBALL_ADOPTION.md",
    ".gumball/repository-os.json",
    ".gumball/proof-broker.json",
    "tools/capabilities.yaml",
    "tools/authority-policy.json",
    ".github/workflows/ci.yml",
)
TEXT_SUFFIXES = {".lua", ".tsv", ".md", ".yml", ".yaml", ".json", ".py"}
CONFLICT_MARKER_RE = re.compile(rb"(?m)^\\s*(?:<{7}(?:\\s|$)|={7}(?:\\s|$)|>{7}(?:\\s|$))")


def fail(message: str) -> None:
    print(f"repository static contract: FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


for relative in REQUIRED_DIRS:
    if not (ROOT / relative).is_dir():
        fail(f"missing source directory: {relative}")

for relative in REQUIRED_FILES:
    if not (ROOT / relative).is_file():
        fail(f"missing repository contract: {relative}")

lua_files = sorted(ROOT.rglob("*.lua"))
tsv_files = sorted(ROOT.rglob("*.tsv"))
if not lua_files:
    fail("anti-noop: no Lua files discovered")
if not tsv_files:
    fail("anti-noop: no TSV files discovered")

for path in ROOT.rglob("*"):
    if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
        continue
    data = path.read_bytes()
    if CONFLICT_MARKER_RE.search(data):
        fail(f"merge-conflict marker found: {path.relative_to(ROOT)}")

try:
    repository_os = json.loads((ROOT / ".gumball/repository-os.json").read_text(encoding="utf-8"))
    proof_broker = json.loads((ROOT / ".gumball/proof-broker.json").read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    fail(f"invalid Gumball JSON policy: {exc}")

for section in ("lifecycle", "projects", "labels", "release", "ci_cost"):
    if section not in repository_os:
        fail(f"repository OS policy missing section: {section}")

if proof_broker.get("proofs") != {}:
    fail("bootstrap expects no enabled heavy proofs yet")

config = (ROOT / "gumball.yaml").read_text(encoding="utf-8")
for expected in ("platform_version: 0.7.0", "profile: standard", "mode: preserve-local"):
    if expected not in config:
        fail(f"gumball.yaml missing expected contract: {expected}")

workflow_text = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted((ROOT / ".github" / "workflows").glob("*.yml"))
)
platform_refs = set(
    re.findall(
        r"karnalooch/engineering-platform/[^@\s]+@([0-9a-f]{40})",
        workflow_text,
    )
)
if platform_refs != {PLATFORM_SHA}:
    fail("engineering-platform workflow pin mismatch: " + (", ".join(sorted(platform_refs)) or "none"))

raw_math_random = sum(path.read_bytes().count(b"math.random") for path in lua_files)
print(
    "repository static contract: PASS "
    f"({len(lua_files)} Lua files, {len(tsv_files)} TSV files; "
    f"existing math.random mentions={raw_math_random}, informational only)"
)
