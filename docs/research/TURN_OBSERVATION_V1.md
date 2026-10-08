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
