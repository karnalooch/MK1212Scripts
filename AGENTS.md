# MK1212Scripts — AI engineering rules

## Project context

This repository is a fork of DETrooper's Medieval Kingdoms 1212 AD scripts for Total War: Attila. Preserve upstream provenance and gameplay behavior unless the active task explicitly changes them.

Start with:

1. `docs/README.md`
2. `docs/ARCHITECTURE.md`
3. `docs/research/README.md` for Attila scripting/debug/runtime or multiplayer work
4. `docs/GUMBALL_ADOPTION.md`
5. the affected Lua/TSV code and its nearest related scripts

## Scope and source preservation

- Make the smallest change that satisfies the active task.
- Do not rewrite unrelated upstream code while performing repository/platform work.
- Keep `campaigns/`, `lua_scripts/`, `script/`, `db/`, `text/` and `ui/` behavior unchanged unless the task explicitly targets game/mod behavior.
- Do not relicense or redistribute Creative Assembly/SEGA game binaries or assets from this repository.
- Runtime executable patching, DRM/CRC bypasses and redistributed modified game binaries are outside normal repository work and require a separate explicit decision.

## Total War source authority

For ATTILA scripting, debugging, multiplayer, runtime instrumentation, or simultaneous-turn research, read `docs/research/README.md` and use this authority order:

1. official Total War: ATTILA Assembly Kit and ATTILA scripting documentation;
2. current MK1212 code at the exact repository SHA;
3. exact-build empirical Attila runtime evidence;
4. modern Total War / WH3 documentation as a design/reference analogy;
5. historical reverse-engineering artefacts such as the Attila 1.6.0-9824 Cheat Engine table.

Rules:

- Never claim a WH3 API exists in Attila because names or engine concepts look similar.
- Never reuse a historical `Attila.dll+offset` as a current address without exact-build revalidation and signature/semantic proof.
- Prefer official Attila scripting, Assembly Kit tools and supported logging before runtime instrumentation.
- Label claims as DOCUMENTED, REPO-OBSERVED, RUNTIME-PROVEN, CROSS-TITLE-REFERENCE, HISTORICAL-RE, HYPOTHESIS, BLOCKED or REJECTED where research status matters.
- Treat the WH3 debug-drawing documentation as an observability/design reference only until an Attila equivalent is proven.
- Treat the 2016 CE table as historical RE methodology/evidence only. Do not implement or distribute its CRC/DRM bypass path.
- Runtime executable patching, binary mutation and integrity-bypass work remain outside normal repository work and require a separate explicit decision.

Canonical research docs:

- `docs/research/ATTILA_ASSEMBLY_KIT.md`
- `docs/research/WH3_DEBUG_DRAWING_REFERENCE.md`
- `docs/research/ATTILA_CE_TABLE_1_6_0_9824.md`
- `docs/research/MP_RUNTIME_RESEARCH_PLAYBOOK.md`

## Multiplayer determinism

Multiplayer work is synchronization-sensitive.

- Any value that changes the shared campaign model must be deterministic across peers.
- Do not introduce Lua `math.random()` into model-changing multiplayer paths. Use an engine/campaign deterministic mechanism only after verifying its Attila behavior.
- Treat local UI events, local faction state, unordered table iteration and asynchronous callbacks as synchronization boundaries until proven otherwise.
- Do not claim a desync/OOS fix from single-player or single-client evidence.
- Exact-SHA multiplayer evidence must record the triggering event/turn and the result on both peers when the task requires runtime proof.
- Existing synchronization hazards are technical debt to audit deliberately; do not silently broaden a change into a mass rewrite.

## Gumball repository contract

This repository adopts Gumball `standard` in `preserve-local` mode.

Core invariants:

- keep a caller-local fail-closed `Aggregate CI gate`;
- pin external Actions and reusable workflows to immutable 40-character SHAs;
- preserve least-privilege workflow permissions;
- never weaken a gate to obtain green CI;
- keep routine PR checks cheap and deterministic;
- treat skipped/deferred heavyweight proof as valid only when policy explicitly says it is not required;
- record reusable downstream engineering improvements under `.gumball/candidates/` before proposing promotion to Gumball.

Changes to `.github/**`, `AGENTS.md`, `gumball.yaml`, `.gumball/**`, `SECURITY.md` or shared automation are high risk and use `Auto-merge: manual`.

## Work tracking

Use the canonical Gumball flow:

1. GitHub Issue with goal, scope/non-scope, acceptance criteria and proof requirements;
2. dedicated branch linked to that issue;
3. PR that references/closes the issue when appropriate;
4. exact-SHA validation before merge.

Do not bypass Issue -> branch -> PR for normal engineering work.

## Validation

For repository-policy changes run:

- `python scripts/gumball.py doctor`
- `python scripts/ci/check_repository.py`

Then use the GitHub Actions results for repository policy, governance, security and the caller-local Aggregate CI gate.

Report validation honestly as PASS, FAIL, BLOCKED or NOT RUN. A workflow that has not executed is not proof.
