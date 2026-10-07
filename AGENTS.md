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
- Label claims as DOCUMENTED, REPO-OBSERVED, RUNTIME-PROVEN, CROSS-TITLE-REFERENCE, HISTORICAL-RE, COMMUNITY-REPORTED, HYPOTHESIS, BLOCKED or REJECTED where research status matters.
- Treat the WH3 debug-drawing documentation as an observability/design reference only until an Attila equivalent is proven.
- Treat the 2016 CE table as historical RE methodology/evidence only. Do not implement or distribute its CRC/DRM bypass path.
- Runtime executable patching, binary mutation and integrity-bypass work remain outside normal repository work and require a separate explicit decision.

Canonical research docs:

- `docs/research/ATTILA_ASSEMBLY_KIT.md`
- `docs/research/WH3_DEBUG_DRAWING_REFERENCE.md`
- `docs/research/ATTILA_CE_TABLE_1_6_0_9824.md`
- `docs/research/MP_RUNTIME_RESEARCH_PLAYBOOK.md`
- `docs/research/ATTILA_MP_STABILITY_FAILURE_CATALOG.md`
- `docs/research/ATTILA_CRASH_OOM_RESOURCE_HAZARDS.md`
- `docs/research/SCRIPT_SAFETY_GUARDRAILS.md`
- `docs/research/TWDLL_OBSERVABILITY_BACKEND.md`
- `docs/research/MP_DUAL_PEER_SIMULATION.md`
- `docs/research/MP_FULL_EXPERIMENTAL_PROFILE.md`

## Native runtime observability

For work involving Lua↔DLL integration, runtime memory/state, engine hooks or semantic fingerprints, read `docs/research/TWDLL_OBSERVABILITY_BACKEND.md` first.

Mandatory rules:

- `karnalooch/twdll` is the preferred experimental native observability backend; preserve upstream provenance to `bukowa/twdll`.
- Load/capability handling MUST fail closed: missing or incompatible DLL disables native diagnostics and MUST NOT break ordinary MK1212 gameplay.
- Raw pointers, module addresses, hook addresses, thread IDs, wall-clock timing and local UI state MUST NOT drive shared multiplayer gameplay.
- twdll-returned semantic values remain observability-only until both-peer exact-build determinism is proven.
- Ordinary gameplay modules SHOULD depend on a narrow `mkmp.runtime` adapter rather than calling twdll directly.
- Native instrumentation MUST be bounded and must not poll or log without ownership/rate limits.
- A runtime-derived gameplay decision requires a separate issue/proof showing peer equality, phase stability, save/load stability and deterministic fallback behaviour.
- Do not use twdll integration as a route to CRC/DRM bypass or modified Attila binary redistribution.

Links:

- our fork: https://github.com/karnalooch/twdll
- upstream: https://github.com/bukowa/twdll
- API docs: https://bukowa.github.io/twdll/

## Multiplayer determinism and script safety

Multiplayer work is synchronization-sensitive. `docs/research/SCRIPT_SAFETY_GUARDRAILS.md` is normative for runtime changes.

Mandatory rules:

- Any value that changes the shared campaign model MUST be deterministic across peers.
- Do not introduce Lua `math.random()`, `math.randomseed`, `os.time` or `os.clock` into shared-model runtime paths. CI rejects obvious new occurrences.
- Every high-impact model mutation MUST have an explicit exactly-once story: listener scope, phase, idempotence token/flag and retry behaviour.
- Treat local UI events, local faction state, unordered `pairs()` iteration and asynchronous callbacks as synchronization boundaries until proven otherwise.
- Local UI handlers MUST NOT directly mutate shared model unless identical execution on all peers is proven.
- Entity lookups MUST fail closed when faction/character/force/region/building state is missing or unexpected.
- Recurring timers, tables, UI components, save serialization and spawned entities MUST be bounded and have cleanup ownership.
- Post-battle, end-turn/AI-cycle, invasion and Papal/diplomacy transitions are high-risk boundaries and require targeted instrumentation when touched.
- Local configuration MUST NOT alter shared MP model unless values are verified identical or transferred through a proven shared mechanism.
- Do not call progressive slowdown/crashing an OOM or memory leak without memory/allocation evidence; use the resource-risk terminology in the canonical docs.
- Do not claim a desync/OOS fix from single-player or single-client evidence.
- Exact-SHA multiplayer evidence must record game build, mod list/load order, host/client roles, triggering event/turn and both-peer results.
- Existing synchronization hazards are technical debt to audit deliberately; do not silently broaden a change into a mass rewrite.
- Any change to MP-sensitive RNG, feature gating, vassal/diplomacy correlation, persistence, deferred operations or native-observability boundaries MUST update or extend the dual-peer simulation/source contracts when behavior changes.
- A green dual-peer simulator is repository-level proof only. It MUST NOT be reported as RUNTIME-PROVEN Attila multiplayer evidence.
- `campaigns/main_attila/common/mkmp_features.lua` is the canonical script-side MP feature registry. Do not add new scattered MP unlock guards when the registry can express the policy.
- Features classified as `experimental_local_ui` or `experimental_choice_event` MAY be enabled in the experimental profile but MUST remain explicitly labeled runtime-unproven until #15-style two-peer evidence exists.
- Peer-local modifiers and external mutators MUST remain fail-closed unless a separate synchronization/environment contract proves them safe.
- The full-profile matriculation test is a mandatory repository-level gate for changes that alter MP feature activation or its declared risk mode.

## Output data integrity — treat it like money in the bank

> **Output data is money in the bank. Do not corrupt it, silently reinterpret it, or casually rewrite it.**

This applies to save-game state, serialized Lua tables, generated files, persistent flags, external helper outputs, fingerprints, logs used as proof, and any data consumed later by MK1212 or tooling.

Mandatory rules:

- Persistent/output formats MUST have explicit ownership and, when evolvable, a schema/version.
- Existing valid saves and outputs MUST be preserved unless an explicit migration plan says otherwise.
- A change that alters persisted meaning MUST define backward-compatibility, migration, defaulting and rollback behaviour.
- Serialization MUST be deterministic when order can affect comparison, hashing, replay, MP parity or future parsing.
- Writers MUST validate inputs and invariants before committing persistent state.
- Partial or failed writes MUST NOT leave a half-valid state that later code accepts as authoritative.
- Destructive overwrite/delete operations MUST be justified, bounded and recoverable where practical.
- Unknown/newer schema versions MUST fail closed rather than being guessed into an older shape.
- Missing fields MUST use documented deterministic defaults; never invent peer-local/random fallback values.
- Save/load code MUST preserve explicit empty state when empty and missing have different meanings.
- Generated IDs, operation tokens and serialized keys MUST be stable and collision-aware.
- Output size/cardinality MUST be bounded where unbounded growth could corrupt saves, exhaust resources or create pathological load times.
- When a migration is risky, prefer copy/transform/verify/swap semantics over in-place mutation.
- Before replacing canonical output, verify the new artifact/state first; do not destroy the last known-good copy just because generation succeeded.
- Runtime diagnostics and fingerprints used as evidence MUST record the exact game build, repository SHA and schema version so old proof is not silently compared to incompatible new output.
- In multiplayer, shared persistent state MUST have identical semantic meaning on every peer; byte-for-byte equality is preferred for canonical serializers and fingerprints where practical.

Review question for every persistence/output change:

```text
If this write is wrong, can it destroy a user's long-running campaign
or make two peers load different semantic state?
```

If the answer is "yes" or "not sure", the change is high risk and requires explicit migration/proof rather than an ad-hoc edit.

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
- `python scripts/ci/check_mp_safety_diff.py --base <base-sha>` when runtime Lua changes are involved
- `python -m unittest discover -s scripts/ci -p "test_mp_*.py" -v` for multiplayer safety contracts

Then use the GitHub Actions results for repository policy, governance, security and the caller-local Aggregate CI gate.

Report validation honestly as PASS, FAIL, BLOCKED or NOT RUN. A workflow that has not executed is not proof.
