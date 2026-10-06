# MK1212Scripts — AI engineering rules

## Project context

This repository is a fork of DETrooper's Medieval Kingdoms 1212 AD scripts for Total War: Attila. Preserve upstream provenance and gameplay behavior unless the active task explicitly changes them.

Start with:

1. `docs/README.md`
2. `docs/ARCHITECTURE.md`
3. `docs/GUMBALL_ADOPTION.md`
4. the affected Lua/TSV code and its nearest related scripts

## Scope and source preservation

- Make the smallest change that satisfies the active task.
- Do not rewrite unrelated upstream code while performing repository/platform work.
- Keep `campaigns/`, `lua_scripts/`, `script/`, `db/`, `text/` and `ui/` behavior unchanged unless the task explicitly targets game/mod behavior.
- Do not relicense or redistribute Creative Assembly/SEGA game binaries or assets from this repository.
- Runtime executable patching, DRM/CRC bypasses and redistributed modified game binaries are outside normal repository work and require a separate explicit decision.

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

GitHub Issues are currently disabled for this fork. Do not fabricate issue tracking.

- While Issues remain disabled, the PR body must carry the task goal, scope/non-scope, acceptance criteria and verification.
- Once Issues are enabled, restore the canonical Gumball Issue -> branch -> PR flow.

## Validation

For repository-policy changes run:

- `python scripts/gumball.py doctor`
- `python scripts/ci/check_repository.py`

Then use the GitHub Actions results for repository policy, governance, security and the caller-local Aggregate CI gate.

Report validation honestly as PASS, FAIL, BLOCKED or NOT RUN. A workflow that has not executed is not proof.
