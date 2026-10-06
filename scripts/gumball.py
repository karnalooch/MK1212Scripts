#!/usr/bin/env python3
"""Gumball repository audit, adoption and promotion helper.

The tool is intentionally standard-library-only so it can run before a consumer
repository has installed project dependencies.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

SHA40 = re.compile(r"^[0-9a-f]{40}$")
USES = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)", re.MULTILINE)
FAIL_OPEN = re.compile(
    r"^\s*continue-on-error:\s*true\s*(?:#.*)?$",
    re.IGNORECASE | re.MULTILINE,
)
WRITE_ALL = re.compile(
    r"^\s*permissions:\s*write-all\s*(?:#.*)?$",
    re.IGNORECASE | re.MULTILINE,
)
AGGREGATE_NAME = re.compile(
    r"""^\s*name:\s*["']?Aggregate CI gate["']?\s*(?:#.*)?$""",
    re.MULTILINE,
)
AGGREGATE_ALWAYS = re.compile(
    r"""^\s*if:\s*["']?\$\{\{\s*always\(\)\s*\}\}["']?\s*(?:#.*)?$""",
    re.MULTILINE,
)

PROFILE_CHOICES = (
    "standard",
    "monorepo",
    "mobile",
    "unreal",
    "release-critical",
)

CANDIDATE_FIELDS = {
    "id",
    "source",
    "category",
    "problem",
    "invariant",
    "evidence",
    "do_not_copy",
    "failure_behavior",
    "status",
}
CANDIDATE_STATES = {"candidate", "proven", "platform"}


def _is_gumball_source(root: Path) -> bool:
    return (
        (root / "VERSION").is_file()
        and (root / "scripts" / "gumball.py").is_file()
        and (root / ".github" / "workflows" / "reusable-governance.yml").is_file()
    )


def _workflow_files(root: Path) -> list[Path]:
    workflows = root / ".github" / "workflows"
    if not workflows.exists():
        return []
    return sorted([*workflows.glob("*.yml"), *workflows.glob("*.yaml")])


def _has_fail_closed_aggregate(root: Path) -> bool:
    for path in _workflow_files(root):
        text = path.read_text(encoding="utf-8")
        if not AGGREGATE_NAME.search(text):
            continue

        lines = text.splitlines()
        for index, line in enumerate(lines):
            if not AGGREGATE_NAME.fullmatch(line):
                continue
            indent = len(line) - len(line.lstrip(" "))
            start = index
            while start > 0:
                candidate = lines[start - 1]
                if candidate.strip() and len(candidate) - len(candidate.lstrip(" ")) < indent:
                    break
                start -= 1
            end = index + 1
            while end < len(lines):
                candidate = lines[end]
                if candidate.strip() and len(candidate) - len(candidate.lstrip(" ")) < indent:
                    break
                end += 1
            if any(AGGREGATE_ALWAYS.fullmatch(candidate) for candidate in lines[start:end]):
                return True
    return False


def _workflow_problems(root: Path) -> list[str]:
    problems: list[str] = []
    for path in _workflow_files(root):
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(root)

        if FAIL_OPEN.search(text):
            problems.append(f"{rel}: fail-open continue-on-error: true")
        if WRITE_ALL.search(text):
            problems.append(f"{rel}: permissions: write-all")

        for match in USES.finditer(text):
            target = match.group(1)
            if target.startswith("./") or target.startswith("docker://"):
                continue
            if "@" not in target:
                problems.append(f"{rel}: external use lacks immutable ref: {target}")
                continue
            _, ref = target.rsplit("@", 1)
            if not SHA40.fullmatch(ref):
                problems.append(f"{rel}: external use is not pinned to 40-char SHA: {target}")
    return problems


def _detect_capabilities(root: Path) -> dict[str, bool]:
    return {
        "python": (root / "pyproject.toml").exists()
        or any(root.glob("requirements*.txt"))
        or any(root.glob("**/requirements*.txt")),
        "node": (root / "package.json").exists()
        or (root / "pnpm-workspace.yaml").exists()
        or (root / "yarn.lock").exists(),
        "monorepo": (root / "pnpm-workspace.yaml").exists()
        or (root / "turbo.json").exists()
        or (root / "nx.json").exists(),
        "unreal": any(root.glob("*.uproject")) or any(root.glob("**/*.uproject")),
        "mobile": (root / "eas.json").exists()
        or (root / "mobile" / "eas.json").exists()
        or (root / "android").exists()
        or (root / "mobile" / "android").exists(),
        "docker": bool(list(root.glob("Dockerfile*")))
        or bool(list(root.glob("**/Dockerfile*")))
        or bool(list(root.glob("docker-compose*.yml")))
        or bool(list(root.glob("compose*.yml"))),
        "mcp_config": any(
            (root / candidate).exists()
            for candidate in (".mcp.json", "mcp.json", ".cursor/mcp.json", ".vscode/mcp.json")
        ),
    }


def audit_repository(root: Path) -> dict[str, Any]:
    root = root.resolve()
    workflow_files = _workflow_files(root)
    return {
        "root": str(root),
        "capabilities": _detect_capabilities(root),
        "contracts": {
            "gumball_config": (root / "gumball.yaml").exists(),
            "agents": (root / "AGENTS.md").exists(),
            "docs_index": (root / "docs" / "README.md").exists(),
            "diagram_style": (root / "docs" / "DIAGRAM_STYLE.md").exists(),
            "tooling_authority": (root / "docs" / "TOOLING_AUTHORITY.md").exists()
            and (root / "tools" / "authority-policy.json").exists(),
            "repository_os_policy": (root / ".gumball" / "repository-os.json").exists(),
            "proof_broker_policy": (root / ".gumball" / "proof-broker.json").exists(),
            "dogfooding": (root / "docs" / "DOGFOODING.md").exists(),
            "gumball_source": _is_gumball_source(root),
            "aggregate_gate": _has_fail_closed_aggregate(root),
            "workflow_count": len(workflow_files),
            "workflow_problems": _workflow_problems(root),
        },
    }


def plan_repository(audit: dict[str, Any]) -> list[dict[str, str]]:
    contracts = audit["contracts"]
    actions: list[dict[str, str]] = []

    for key, path in (
        ("gumball_config", "gumball.yaml"),
        ("agents", "AGENTS.md"),
        ("docs_index", "docs/README.md"),
        ("diagram_style", "docs/DIAGRAM_STYLE.md"),
        ("tooling_authority", "docs/TOOLING_AUTHORITY.md + tools/authority-policy.json"),
        ("repository_os_policy", ".gumball/repository-os.json"),
        ("proof_broker_policy", ".gumball/proof-broker.json"),
    ):
        if contracts[key]:
            actions.append({"action": "KEEP", "path": path, "reason": "already present; inspect before modifying"})
        else:
            actions.append({"action": "ADD", "path": path, "reason": "missing baseline contract"})

    if contracts["aggregate_gate"]:
        actions.append({"action": "KEEP", "path": ".github/workflows/*", "reason": "fail-closed Aggregate CI gate detected"})
    else:
        actions.append({"action": "MODIFY", "path": ".github/workflows/*", "reason": "caller-local fail-closed Aggregate CI gate is missing"})

    if contracts["workflow_problems"]:
        actions.append({"action": "MODIFY", "path": ".github/workflows/*", "reason": "workflow safety violations detected"})

    if audit["capabilities"]["monorepo"]:
        actions.append({"action": "PLAN", "path": "CI classifier", "reason": "monorepo detected; evaluate affected-test and anti-no-op contracts"})
    if audit["capabilities"]["unreal"]:
        actions.append({"action": "PLAN", "path": "unreal profile", "reason": "Unreal project detected; keep runtime/visual proof consumer-owned"})
    if audit["capabilities"]["mobile"]:
        actions.append({"action": "PLAN", "path": "mobile profile", "reason": "mobile/native surface detected; separate PR smoke from release proof"})
    if audit["capabilities"]["mcp_config"]:
        actions.append({"action": "KEEP", "path": "MCP/tool config", "reason": "existing MCP configuration detected; preserve endpoints/secrets and map capabilities instead of replacing it"})

    return actions


def _gumball_self_problems(root: Path) -> list[str]:
    if not _is_gumball_source(root):
        return []

    problems: list[str] = []

    if not (root / "docs" / "DOGFOODING.md").is_file():
        problems.append("docs/DOGFOODING.md is missing")
    if not (root / "tools" / "capabilities.yaml").is_file():
        problems.append("tools/capabilities.yaml is missing")
    if not (root / "tools" / "authority-policy.json").is_file():
        problems.append("tools/authority-policy.json is missing")
    if not (root / "docs" / "TOOLING_AUTHORITY.md").is_file():
        problems.append("docs/TOOLING_AUTHORITY.md is missing")
    if not (root / "docs" / "VISUAL_ENGINEERING.md").is_file():
        problems.append("docs/VISUAL_ENGINEERING.md is missing")

    version = (root / "VERSION").read_text(encoding="utf-8").strip()
    config_text = (root / "gumball.yaml").read_text(encoding="utf-8")
    match = re.search(r"^platform_version:\s*([^\s#]+)", config_text, re.MULTILINE)
    if not match:
        problems.append("gumball.yaml platform_version is missing")
    elif match.group(1) != version:
        problems.append(
            f"VERSION ({version}) != gumball.yaml platform_version ({match.group(1)})"
        )

    try:
        repository_policy = json.loads(
            (root / ".gumball" / "repository-os.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as exc:
        problems.append(f"repository OS policy is invalid: {exc}")
    else:
        for key in ("lifecycle", "projects", "labels", "release", "ci_cost"):
            if key not in repository_policy:
                problems.append(f"repository OS policy missing section: {key}")

    required_repository_os_paths = (
        "docs/REPOSITORY_LIFECYCLE.md",
        "docs/PROJECTS_FLOW.md",
        "docs/RELEASE_LINEAGE.md",
        "docs/LABELS.md",
        "docs/CI_COST_GOVERNOR.md",
        "scripts/ops/repository_os.py",
        "scripts/ops/github_ops.py",
        ".github/workflows/repository-ops.yml",
        "docs/PROOF_BROKER.md",
        ".gumball/proof-broker.json",
        "scripts/ops/proof_broker.py",
        ".github/workflows/proof-broker.yml",
    )
    for relative in required_repository_os_paths:
        if not (root / relative).is_file():
            problems.append(f"repository OS contract missing: {relative}")

    candidate_dir = root / ".gumball" / "candidates"
    platform_candidates = 0
    if candidate_dir.exists():
        for path in candidate_dir.glob("*.json"):
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if payload.get("status") == "platform":
                platform_candidates += 1
    if platform_candidates < 1:
        problems.append("at least one platform promotion provenance record is required")

    ci_path = root / ".github" / "workflows" / "ci.yml"
    if not ci_path.is_file():
        problems.append(".github/workflows/ci.yml is missing")
        return problems

    ci_text = ci_path.read_text(encoding="utf-8")
    required_ci_markers = (
        "python scripts/gumball.py doctor",
        "python scripts/gumball.py promote",
        "python scripts/ci/check_docs_index.py",
        "python scripts/ci/validate_tooling_authority.py",
        "python -m unittest scripts/ci/test_gumball.py -v",
        "python -m unittest scripts/ci/test_repository_os.py -v",
        "python -m unittest scripts/ci/test_github_ops.py -v",
        "python -m unittest scripts/ci/test_proof_broker.py -v",
    )
    for marker in required_ci_markers:
        if marker not in ci_text:
            problems.append(f"Gumball CI does not self-prove: {marker}")

    return problems


def doctor_repository(root: Path) -> tuple[bool, list[tuple[str, str, str]]]:
    audit = audit_repository(root)
    contracts = audit["contracts"]
    checks: list[tuple[str, str, str]] = []

    def add(name: str, ok: bool, detail: str) -> None:
        checks.append((name, "PASS" if ok else "FAIL", detail))

    add("gumball config", contracts["gumball_config"], "gumball.yaml")
    add("agent contract", contracts["agents"], "AGENTS.md")
    add("docs index", contracts["docs_index"], "docs/README.md")
    add("diagram style", contracts["diagram_style"], "docs/DIAGRAM_STYLE.md")
    add(
        "tooling authority",
        contracts["tooling_authority"],
        "docs/TOOLING_AUTHORITY.md + tools/authority-policy.json",
    )
    add("repository OS policy", contracts["repository_os_policy"], ".gumball/repository-os.json")
    add("proof broker policy", contracts["proof_broker_policy"], ".gumball/proof-broker.json")
    add("workflow discovery", contracts["workflow_count"] > 0, f"{contracts['workflow_count']} workflow(s)")
    add("aggregate gate", contracts["aggregate_gate"], "caller-local fail-closed Aggregate CI gate")

    workflow_problems = contracts["workflow_problems"]
    add(
        "workflow safety",
        not workflow_problems,
        "no mutable external refs / fail-open controls"
        if not workflow_problems
        else "; ".join(workflow_problems),
    )

    self_problems = _gumball_self_problems(root.resolve())
    if contracts["gumball_source"]:
        add(
            "Gumball dogfooding",
            not self_problems,
            "source repository satisfies self-hosting contract"
            if not self_problems
            else "; ".join(self_problems),
        )

    return all(status == "PASS" for _, status, _ in checks), checks


def _generated_config(profile: str) -> str:
    return f"""schema_version: 1
name: Gumball
profile: {profile}
adoption:
  mode: preserve-local
ci:
  aggregate_gate: caller-local
  fail_closed: true
  anti_noop: true
docs:
  index_required: true
  blueprint_diagram_style: required
tooling:
  authority: repository
  admission_policy: proven-before-custom
  authoritative_external_tool_return_path: deterministic-required
  generated_artifact_freshness: content-or-digest
  dev_editor_proof_shipping_default: excluded
repository_os:
  policy: .gumball/repository-os.json
  lifecycle: required
  labels: required
  release_lineage: required_for_release_profiles
  ci_cost_governor: required
proof_broker:
  policy: .gumball/proof-broker.json
  trusted_dispatch: supported
  manual_fallback: required
agents:
  preserve_local_instructions: true
  evaluate_upstream_promotion: true
"""


def _generated_agents() -> str:
    return """# Repository agent rules

## Gumball baseline

- Read the repository and its documentation entry point before editing.
- Preserve project-specific contracts and stronger local safety controls.
- Do not weaken tests or CI to obtain green results.
- Keep the final Aggregate CI gate caller-local and fail closed.
- Use immutable external Action/workflow references.
- Treat heavy runtime, visual, emulator and hardware proof as explicit project/profile policy.
- Review proven tooling/platform-native/proven OSS before inventing custom tooling.
- Keep accepted tool output deterministic and repository-owned; SaaS-only state is research/convenience, not SSOT.
- Keep dev/editor/proof tooling outside shipping artifacts by default and record exact provenance/lock evidence.
- For visual profiles, prefer composition-first design and production-component workbenches with deterministic fixtures and asset-off inspection.
- When Proof Broker is configured, request heavyweight proof through its exact-SHA label/comment contract; keep manual workflow_dispatch as fallback only.
- Evaluate reusable CI, governance, security, docs, tooling, MCP and agent-workflow improvements for promotion back to Gumball.
- Report validation as PASS, FAIL, BLOCKED or NOT RUN.
"""


def _generated_diagram_style() -> str:
    return """# Blueprint diagram style

This repository follows the Gumball Mermaid diagram language inspired by Unreal Engine Blueprint graphs.

Use it for new or substantially revised architecture, CI/CD, agent, tooling, data-flow and runtime-proof diagrams. Preserve correct existing diagrams until their owning SSOT is materially changed.

## Canonical classes

```mermaid
flowchart LR
    IN["INPUT<br/>Source"] --> EXEC["EXECUTE<br/>Step"]
    EXEC --> OUT["OUTPUT<br/>Verified"]

    classDef input fill:#303846,stroke:#8ea1b8,color:#f7f9fc,stroke-width:2px;
    classDef exec fill:#123f73,stroke:#49a2ff,color:#ffffff,stroke-width:3px;
    classDef tool fill:#4b2f69,stroke:#b77cff,color:#ffffff,stroke-width:2px;
    classDef decision fill:#69470e,stroke:#f0a72f,color:#ffffff,stroke-width:3px;
    classDef success fill:#1f5736,stroke:#63d889,color:#ffffff,stroke-width:3px;
    classDef danger fill:#6b2429,stroke:#ff6b73,color:#ffffff,stroke-width:3px;
    classDef owned fill:#34373d,stroke:#9da4ae,color:#ffffff,stroke-width:2px;
    classDef evidence fill:#164d5c,stroke:#5bd6ef,color:#ffffff,stroke-width:2px;

    class IN input;
    class EXEC exec;
    class OUT success;

    linkStyle default stroke-width:2px;
```

Solid edges are required/execution flow. Dashed edges are feedback, provenance or optional relationships. Label meaningful transitions such as PASS, FAIL, adopt and promote.

Project-specific extensions are allowed. Reusable visual conventions should be evaluated for promotion back to Gumball.
"""


def _source_file(relative: str) -> str:
    source = Path(__file__).resolve().parents[1] / relative
    if source.is_file():
        return source.read_text(encoding="utf-8")
    raise RuntimeError(f"canonical Gumball source file is unavailable: {relative}")


def _generated_repository_os() -> str:
    return _source_file(".gumball/repository-os.json")


def _generated_docs_index() -> str:
    return """# Documentation

This file is the documentation entry point.

Before implementation, identify the authoritative document for the affected area.
Historical snapshots and evidence do not override a current SSOT.

## Authority map

Populate this table with project-owned sources of truth before treating Gumball adoption as complete.

| Area | Authoritative document |
|---|---|
| Product / scope | TODO |
| Architecture | TODO |
| Development | TODO |
| CI / release | TODO |
"""


def apply_baseline(root: Path, profile: str, write: bool) -> list[tuple[str, str]]:
    root = root.resolve()
    planned = [
        (root / "gumball.yaml", _generated_config(profile)),
        (root / "AGENTS.md", _generated_agents()),
        (root / "docs" / "README.md", _generated_docs_index()),
        (root / "docs" / "DIAGRAM_STYLE.md", _generated_diagram_style()),
        (root / "docs" / "TOOLING_AUTHORITY.md", _source_file("docs/TOOLING_AUTHORITY.md")),
        (root / "tools" / "authority-policy.json", _source_file("tools/authority-policy.json")),
        (root / "docs" / "PROOF_BROKER.md", _source_file("docs/PROOF_BROKER.md")),
        (root / ".gumball" / "repository-os.json", _generated_repository_os()),
        (root / ".gumball" / "proof-broker.json", _source_file(".gumball/proof-broker.json")),
        (root / "scripts" / "ops" / "repository_os.py", _source_file("scripts/ops/repository_os.py")),
        (root / "scripts" / "ops" / "github_ops.py", _source_file("scripts/ops/github_ops.py")),
        (root / ".github" / "workflows" / "repository-ops.yml", _source_file(".github/workflows/repository-ops.yml")),
        (root / ".github" / "workflows" / "proof-broker.yml", _source_file(".github/workflows/proof-broker.yml")),
        (root / "scripts" / "ops" / "proof_broker.py", _source_file("scripts/ops/proof_broker.py")),
        (root / "templates" / "release-manifest.json", _source_file("templates/release-manifest.json")),
        (root / ".gumball" / "candidates" / "README.md",
         "# Gumball promotion candidates\n\nRecord reusable downstream engineering improvements here.\n"),
    ]
    if profile in {"mobile", "unreal"}:
        planned.append(
            (root / "docs" / "VISUAL_ENGINEERING.md", _source_file("docs/VISUAL_ENGINEERING.md"))
        )

    results: list[tuple[str, str]] = []
    for path, content in planned:
        rel = str(path.relative_to(root))
        if path.exists():
            results.append((rel, "KEEP existing"))
            continue
        if not write:
            results.append((rel, "ADD (dry-run)"))
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        results.append((rel, "ADDED"))
    return results


def scan_candidates(root: Path) -> tuple[bool, list[str]]:
    candidate_dir = root.resolve() / ".gumball" / "candidates"
    messages: list[str] = []
    ok = True

    if not candidate_dir.exists():
        return True, ["no candidate directory"]

    files = sorted(candidate_dir.glob("*.json"))
    if not files:
        return True, ["no JSON promotion candidates"]

    for path in files:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            ok = False
            messages.append(f"{path.name}: invalid JSON: {exc}")
            continue

        missing = sorted(CANDIDATE_FIELDS - set(payload))
        if missing:
            ok = False
            messages.append(f"{path.name}: missing fields: {', '.join(missing)}")
            continue

        if payload.get("status") not in CANDIDATE_STATES:
            ok = False
            messages.append(f"{path.name}: invalid status {payload.get('status')!r}")
            continue

        messages.append(f"{path.name}: {payload['status']} / {payload['category']} / {payload['id']}")

    return ok, messages


def _repo_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repo", default=".", help="Repository root (default: current directory)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="gumball", description="Gumball engineering-platform helper")
    sub = parser.add_subparsers(dest="command", required=True)

    audit = sub.add_parser("audit", help="Inspect repository capabilities and baseline contracts")
    _repo_arg(audit)

    plan = sub.add_parser("plan", help="Produce a conservative adoption plan")
    _repo_arg(plan)

    doctor = sub.add_parser("doctor", help="Validate required Gumball repository contracts")
    _repo_arg(doctor)

    apply = sub.add_parser("apply", help="Create only missing baseline files; never overwrite existing files")
    _repo_arg(apply)
    apply.add_argument("--profile", choices=PROFILE_CHOICES, default="standard")
    apply.add_argument("--write", action="store_true", help="Actually create missing files; default is dry-run")

    promote = sub.add_parser("promote", help="Validate downstream promotion candidates")
    _repo_arg(promote)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = Path(args.repo)

    if args.command == "audit":
        print(json.dumps(audit_repository(root), indent=2, sort_keys=True))
        return 0

    if args.command == "plan":
        audit = audit_repository(root)
        for item in plan_repository(audit):
            print(f"{item['action']:>6}  {item['path']}: {item['reason']}")
        return 0

    if args.command == "doctor":
        ok, checks = doctor_repository(root)
        for name, status, detail in checks:
            print(f"{status:4}  {name}: {detail}")
        return 0 if ok else 1

    if args.command == "apply":
        for path, result in apply_baseline(root, args.profile, args.write):
            print(f"{result:13} {path}")
        if not args.write:
            print("dry-run only; re-run with --write to create missing baseline files")
        return 0

    if args.command == "promote":
        ok, messages = scan_candidates(root)
        for message in messages:
            print(message)
        return 0 if ok else 1

    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
