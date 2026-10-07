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
    "docs/research/ATTILA_MP_STABILITY_FAILURE_CATALOG.md",
    "docs/research/ATTILA_CRASH_OOM_RESOURCE_HAZARDS.md",
    "docs/research/SCRIPT_SAFETY_GUARDRAILS.md",
    ".gumball/repository-os.json",
    ".gumball/proof-broker.json",
    "tools/capabilities.yaml",
    "tools/authority-policy.json",
    ".github/workflows/ci.yml",
    "scripts/ci/check_mp_safety_diff.py",
    "scripts/ci/mp_simulation.py",
    "scripts/ci/mp_contracts.json",
    "scripts/ci/test_mp_dual_peer.py",
    "scripts/ci/test_mp_source_contracts.py",
    "scripts/ci/test_mp_debug_logging.py",
    "scripts/ci/compare_mp_debug_logs.py",
    "campaigns/main_attila/common/mkmp_debug.lua",
    "docs/research/MP_DUAL_PEER_SIMULATION.md",
    "docs/research/MP_DEBUG_LOGGING.md",
    "native/twdll/AGENTS.md",
    "native/twdll/CMakeLists.txt",
    "native/twdll/LICENSE",
    "native/twdll/UPSTREAM.md",
    "native/twdll/src/main.cpp",
    "native/twdll/tests/attila/tests.save",
    "native/twdll/vendor/minhook/CMakeLists.txt",
    "native/twdll/vendor/minhook/LICENSE.txt",
    "trivy.yaml",
    ".trivyignore.yaml",
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

twdll_provenance = (ROOT / "native/twdll/UPSTREAM.md").read_text(encoding="utf-8")
for expected in (
    "karnalooch/twdll",
    "bukowa/twdll",
    "85c4db9836e3150df8ec5b38315de9940f8d624c",
    "TsudaKageyu/minhook",
    "d94c64d32ea37bc4f5ee47d580709f70c6fb6080",
):
    if expected not in twdll_provenance:
        fail(f"native twdll provenance missing: {expected}")

if (ROOT / "native/twdll/.gitmodules").exists():
    fail("native/twdll must vendor MinHook; nested .gitmodules is not allowed")

if (ROOT / ".trivyignore").exists():
    fail("global .trivyignore is not allowed; keep security exceptions path-scoped")

trivy_config = (ROOT / "trivy.yaml").read_text(encoding="utf-8").strip()
if trivy_config != "ignorefile: .trivyignore.yaml":
    fail("trivy.yaml must only select the path-scoped .trivyignore.yaml")

trivy_ignore = (ROOT / ".trivyignore.yaml").read_text(encoding="utf-8")
for expected in (
    "AVD-DS-0002",
    "native/twdll/docs/lua/ldoc/Dockerfile",
    "Imported upstream LDoc tooling",
):
    if expected not in trivy_ignore:
        fail(f"Trivy exception contract missing: {expected}")
if trivy_ignore.count("- id:") != 1 or trivy_ignore.count("paths:") != 1:
    fail("Trivy exception contract must contain exactly one path-scoped finding")

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
