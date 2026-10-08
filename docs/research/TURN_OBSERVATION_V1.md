# Issue #35 — TurnObservationV1: safe Attila turn-state inventory

Status: **REPO-OBSERVED / automated fixture proof only**. No simultaneous-turn or real MP capability is claimed.

## Goal and evidence

Attila's MK1212 runtime Lua adapter already used `cm:model():turn_number()` for diagnostics. It does **not** establish a supported API for local-player identity, active-turn ownership, input gates or replication. Prior PR #45 one-session WORLD/faction-parity observations are not evidence that human turns can overlap.

`MKMP_Runtime_Get_Turn_Observation_V1()` returns a fresh Lua table:

| Field | V1 value/source | Evidence |
| --- | --- | --- |
| `schema` | `1` | implementation contract |
| `source` | `attila_lua_campaign_model` | adapter label, not independent engine attestation |
| `available` | true only if model's validated turn number was readable | Lua source/fixture |
| `reason` | `model_unavailable`, `turn_number_unavailable` or `partial_lua_turn_only` | implementation |
| `turn_number` | validated nonnegative integer or `"unknown"` | existing `cm:model():turn_number()` usage |
| `multiplayer` | boolean only when `cm:is_multiplayer()` returned boolean, else unknown | existing adapter API |
| `local_faction`, `active_faction` | `"unknown"` | **UNRESOLVED**, never inferred |
| `local_player_index`, `active_player_index` | `"unknown"` | **UNRESOLVED** |
| `phase`, `input_enabled` | `"unknown"` | **UNRESOLVED** |

`MKMP_Runtime_Get_Turn_Observation_Event_V1(event_name)` attaches a callback *label* under `event` with `event_source="lua_callback_label_unverified"`. Callback names never establish `phase` or `active_faction`.

No DLL loading, new hooks, pointers, writes, command submissions, UI bypass, turn manipulation or changed gameplay authority. **Do not use V1 output to govern MP gameplay**.

## Fixture matrix

- Missing `cm`, throwing `cm:model()`, throwing/missing `turn_number`: explicit unavailable.
- Negative/fractional turn numbers: unknown rather than accepted.
- SP and MP with consistent mocked turn number: partial observations only, owner remains unknown.
- Turn event label: cannot assert active player or phase.
- Repeated observations and out-of-order retained snapshots: separate tables, no monotonicity assumptions.
- Simulated Lua recreation/save-load counter reset: observed numbers may restart; this is not proof of engine save/load correctness.
- No native DLL required.

Commands: `python -m unittest scripts/ci/test_turn_observation_v1.py`; optional `lua5.1 scripts/ci/fixtures/turn_observation_v1.lua campaigns/main_attila/common/mkmp_runtime.lua`. Python test skips dynamic Lua fixture if no Lua interpreter; that outcome must **not** be reported as end-to-end PASS.

## Command gate investigation matrix

| Command | Engine gate | Multiplayer replication | Status |
| --- | --- | --- | --- |
| Construction | unknown | unknown | NOT OBSERVED |
| Research | unknown | unknown | NOT OBSERVED |
| Recruitment | unknown | unknown | NOT OBSERVED |
| Army movement | unknown | unknown | NOT OBSERVED |
| Agent movement/action | unknown | unknown | NOT OBSERVED |
| Diplomacy | unknown | unknown | NOT OBSERVED |
| End turn | unknown | unknown | NOT OBSERVED |
| Battle trigger | unknown | unknown | NOT OBSERVED |

## Next decision gate

**INVESTIGATE**, not GO: compare local player and active turn identity on real SP/AI transitions using *documented* scripting interfaces first; only after evidence review and publisher-compliance assessment (#60) design separately authorized read-only native instrumentation. Do not introduce guessed addresses or force non-active commands. A two-peer test is necessary for an actual simultaneous-turn multiplayer claim.

Evidence categories: DOCUMENTED / REPO-OBSERVED / RUNTIME-PROVEN / HISTORICAL-RE / HYPOTHESIS / BLOCKED. CI/source tests alone are never RUNTIME-PROVEN.

## Stacked PR CI mechanics

PR #61 targets the unmerged runtime integration branch (PR #45). GitHub Actions originally allowed pull-request targets only on `master`; CI trigger coverage was expanded on the parent branch to include `feat/44-mk1212-twdll-runtime-integration`. The child branch adds its dedicated V1 test step. A green workflow must be checked at the **exact child HEAD**; workflow dispatch and completion must not be inferred from committed YAML alone. Revert the temporary stacked-branch trigger after #45 lands, if no longer needed.

## Governance and release checklist

For PR #61, high-risk governance requires the exact PR-body marker `Auto-merge: manual`. The explicit marker was added to the PR after CI #94 identified the missing policy text; the change is administrative and does not alter game behavior. The PR must remain manually merged, and the **latest exact HEAD** must have green Aggregate CI plus a verified artifact before release.

## AEEF Flight Recorder V1 — campaign event trace

The SP harness now records a small **read-only** event stream called `flight_v1`:
- `initializer`, `FactionTurnStart`, `FactionTurnEnd` (only when the current Attila build actually dispatches them).
- Sequential per-Lua-state index, callback event, guarded campaign turn, multiplayer boolean, guarded event faction label.
- **`owner=unknown` and `phase=unknown` are deliberate:** the callback label does not prove ownership.
- Hard cap **48** flight records per Lua state, together with the pre-existing overall trace budget of 128 lines / 64 KiB.
- Parsed under `coverage.json.flight_recorder` with count, event distribution and sequence validity; no claim of completeness, and no inferred input/command permissions.
- The baseline separate WORLD probe remains capped; flight events cannot modify state or use new native hooks.
- Unsupported callback APIs fail softly; observing no event is `NOT_OBSERVED`, not engine inactivity proof.

### One-session operator path

Run native probe once, open a single-player campaign, perform ordinary commands if available, end 1–2 turns, optionally save/load or fight, exit normally and submit ONE `MK1212-PR45-SP-EVIDENCE-*.zip`. Check `result.json`, `coverage.json` and `PR45_RUNTIME_TRACE.txt`. Native mode remains separate from optional no-DLL fallback. Workshop backup and rollback continue to be mandatory.

### Coverage limitations

This is **not yet a complete flight recorder for all game internals**: there is no universal Attila command bus or read-only network replication API established here. Do not claim that army movement, recruitment, diplomacy, saves, battles or every AI action are captured unless source-supported event probes and real runtime observations establish that. Expanding the allowlist requires an Attila-specific API check and independent tests. This release establishes a guarded instrumentation backbone, not simultaneous multiplayer turns.

## Attila-first observation V2 / optional twdll comparison

Additive `MKMP_Runtime_Get_Turn_Observation_V2()` makes a bounded (`<=1000` factions) **once-per-initializer** attempt to classify:
- `model:is_player_turn()`: true/false only if the Attila Lua model method exists and succeeds;
- `model:faction_is_local(faction_key)`: local factions; completeness is separately `complete/incomplete/unknown`;
- `faction:is_human()`: human-controlled factions; also independently classified for completeness;
- `FACTION_TURN`: the MK1212 script callback's last cached faction name, **never** the authoritative engine owner;
- native `twdll.world.GetFactionCount()` parity, only via existing safe/optional wrapper; no new hooks or forced state.

The V2 census logs `turn_v2` once per initialized Lua campaign segment, not at every AI faction turn, avoiding hundreds of scans. Per-event V1 flight trace is unchanged and still bounded. `active_faction` stays `unknown`. A native getter may depend on invasive hook installation: optional parity is *corroboration*, not an alternative owner API.

**Source authority:** Attila Extra Scripting Guides/Assembly Kit for the target model/faction interface; current MK1212's `FactionTurnStart_Global` and `FACTION_TURN` for script-local context; monorepo native `faction.cpp`, `character.cpp`, `military_force.cpp` for diagnostic possibilities. WH2/WH3 pages are comparative only and do not establish Attila availability. Mocked Lua tests are not engine runtime proof.

### Comparison before expanding the native adapter

| Question | First choice | Native optional candidate | Limits |
| --- | --- | --- | --- |
| Local player identity | `model:faction_is_local(key)` | none needed | API must be runtime-proven on our build |
| Human/AI classification | `faction:is_human()` | none needed | doesn't identify active owner |
| Player turn flag | `model:is_player_turn()` | none needed | no specific owner |
| Number of factions | `world:faction_list():num_items()` | `world.GetFactionCount()` | count parity is not ownership proof |
| Research, treasury, AP, queue | inspect current Attila scripting interface first | `GetTechnologyStatus`, `GetTreasury`, `GetActionPoints`, `GetRecruitmentQueueSize` | not wired until semantic and safety proof |
| True active turn owner / command permissions | unknown | no proven safe API | **BLOCKED** pending evidence; don't inject writes |

No direct call to `grant_faction_handover`, `SetActionPoints`, `SetTreasury` or other mutator belongs in this observational work.
