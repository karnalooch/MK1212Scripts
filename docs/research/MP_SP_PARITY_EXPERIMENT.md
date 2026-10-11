# MK1212: SP → MP parity experiment — Issue #66

Status: **DRAFT, script-action fixes and reproducible packs / NO REAL-GAME MP PROOF** (2026-10-11).
Authority: `AGENTS.md`, `SCRIPT_SAFETY_GUARDRAILS.md`, `MP_RUNTIME_RESEARCH_PLAYBOOK.md`.

## Intent
Expose functionality present in a single-player campaign but withheld in multiplayer,
on two physical PCs with distinct **licensed Steam accounts**. Never use Goldberg or
Sandboxie as the multiplayer proof environment. The original game binary remains unchanged.

The source registry keeps experimental gates disabled by default. The release
builder also produces the requested **full-experimental** pack with all wired
experimental gates enabled. Both profiles contain the script-action fixes below.
The baseline profile is a control for the experimental gates; it is not a copy
of the original unmodified scripts.

The subsequent [N0–N4 tranche](MP_N0_N4_IMPLEMENTATION.md), Issue #69, adds an
unconditional MP authority boundary for captured local actions. Enabling an
initialization gate can display a feature but cannot enable its unproven local
script mutation. This includes decision/Papal-loan submission, Buffer State
creation, region trades, annex start/cancel and the captured Population actions.
N4 candidate-batch receipt is not gameplay execution. The shared codec remains
schema 3, while new owner metadata also requires a pre-update save for rollback.

The user's control observation — synchronization worked with scripts disabled —
prioritizes script execution, local inputs and save state. The earlier PR45
`no-dll` ZIP is a different control: scripts were enabled and its sessions were SP.

Release and installation: [PACK_RELEASE](../runtime/PACK_RELEASE.md).
Detailed findings and evidence limits: [MP_SCRIPT_ACTION_FINDINGS](MP_SCRIPT_ACTION_FINDINGS.md).

## Script-action repair tranche

| Boundary | Implemented behavior | Proof |
| --- | --- | --- |
| Local difficulty | Shared MP War Weariness, rebel army composition and Crusade defender experience use one content-defined normal level, 0. SP keeps the chosen level. Engine difficulty settings are not changed. | Real production Lua with opposite local difficulty values on two isolated peers. Official Attila documentation calls the API's value local. |
| Repeated initialization and turns | War Weariness initializes once and owns a bounded, saved faction/round ledger. It claims each passive turn update before mutations; a failed partial update is not blindly retried. | Production Lua duplication, re-entry, partial failure, next-turn and save/reload scenarios. |
| Mecca events | Unique raze listener, one initializer, stable faction-key persistence and entity validation. Repeated destruction does not duplicate the transition; recapture permits a later real destruction. | Production Lua listener registry and save/reload scenarios. |
| Pope panel RNG | Presentation placeholders no longer consume campaign RNG and reuse existing logos. | HOST-only refreshes leave the next shared production RNG draw equal. College initialization is currently commented out: this is a latent UI hazard, not an established ordinary-MP root cause. |
| Buffer timer | Captured region/master/vassal intent, bounded namespaced operation, duplicate callback refusal and an owned save lifecycle. Only confirmed waiting-transfer state may be rearmed after load. | Production Lua confirmation/selection changes and asynchronous callbacks. Local UI has no newly proven MP transport; this gate stays experimental. |
| Deferred transfers | Validated queue capped at 64, stable ordering, duplicate load entries collapsed, already-owned targets are no-ops. Each record is claimed separately; an engine error preserves later queued work and attempts governor cleanup. | Production Lua unsafe-AI-turn, reload, re-entry, missing entity and partial-error scenarios. |
| Saves | Schema 3 escapes delimiters/control characters, preserves empty strings and canonical ordering, bounds encoding as it accumulates, and reads numeric values under dot/comma locales. | Actual generic, population, decision and nickname functions, old schema migration and corrupt-input refusals. |
| Diagnostics | Pack source/profile identity, payload checksums, guarded file and formatting errors. Bootstrap-only traces cannot pass the comparator. | Production logger/RNG/save injection tests and parser regressions. |

The compiled test interpreter is the repository's Lua **5.1.2** source with its
configured **float** number type. The tests exercise actual Lua functions with
mocked Attila interfaces; they do not emulate the multiplayer engine.

## Save compatibility and rollback

Common tables now write **schema 3** with the frame `MK1212_SAVE_V3|` and
percent-escaped scalar bytes. Readers preserve valid legacy schemas 0 (absent),
1 and 2 literally, including pre-existing percent sequences, and migrate them
on the next successful save. A legacy string that merely starts with the new
prefix remains literal. Empty nested lists and empty new scalar strings remain
distinct, supported values.

Unknown schemas, invalid numeric/boolean values, duplicate map keys and
malformed or oversized records are rejected. An already ambiguous old city
record containing an unescaped comma cannot be reconstructed reliably; the
reader does not guess its original text. The 20,000-entry limit continues to
count map rows, and the 1 MiB byte limit includes the new frame. A legacy payload
exactly at the old byte ceiling may therefore need reduction before migration.

Validation completes before either engine write. The frame detects a schema-3
sidecar paired with an unframed payload; it cannot detect an older valid
schema-3 payload left by a later engine write failure. Attila owns the outer
save transaction. Two `cm:save_value` calls are not a transaction supplied by
this codec.

War Weariness and Buffer States also own separate small lifecycle metadata.
Unknown/unsafe operation states are retained and blocked rather than replayed.
Read their source and the findings document for the exact supported transitions.

**Rollback uses the preserved save from before this update.** Older scripts do
not understand the schema-3 payload. This applies to saves created by either
the baseline or full-experimental release. Do not point older scripts at a
newly migrated campaign and assume the result is compatible.

## Verified initialization-gate inventory (repo observed)

| Feature | Source gate | Experimental switch | Risk/proof status |
| --- | --- | --- | --- |
| Annex Vassals | `mechanics/main.lua` | `annex_vassals` | BLOCKED pending synchronized local UI/region mutation |
| Buffer States | `mechanics/main.lua` | `buffer_states` | BLOCKED pending `create_force`, vassal and deferred-transfer determinism |
| Decisions UI | `mechanics/main.lua` | `decisions` | BLOCKED pending host/peer decision ownership |
| HRE mechanics | `mechanics/main.lua` | `hre` | BLOCKED pending elections/decrees/timers/serialization |
| Population | `mechanics/main.lua` | `population` | BLOCKED pending battles, recruitment, settlement and save/load peer proof |
| Region Trading | `mechanics/main.lua` | `region_trading` | BLOCKED pending local offer/UI → shared ownership sync |
| Occupation gift decision | `common/main.lua` | `occupation_decisions` | BLOCKED pending deterministic transfer event |
| HRE + Sicily story | `story/main.lua` | `story_hre_sicily` | BLOCKED pending diplomacy/dilemma exactly-once |
| Lucky Nations | `luckynations/main.lua` + `lucky_nations.lua` | `lucky_nations` | BLOCKED pending same-source treasury/effect events and persistence |
| Three challenges | `challenges/main.lua` | `challenge_judgement_day`, `challenge_no_retreat`, `challenge_this_is_total_war` | BLOCKED pending AI, battle, diplomacy and save/load proof; conflicts between modes must be assessed |

### Additional nested guards discovered by source audit

The first entrypoint inventory was not sufficient: SP-only paths were found **inside**
modules that already execute in MP. These have now been given explicit lab gates:

| Nested feature | Source | Opt-in key |
| --- | --- | --- |
| Manual kingdom formation/restoration decisions | `kingdoms/kingdom_{armenia,byzantium,golden_horde,ilkhanate,italy,persia,poland,serbia,spain}.lua`; `byzantium/byzantium_reconquest.lua` | `kingdom_decisions` |
| Human kingdom/empire rank choices vs automatic MP promotion | `mechanics/mechanics_dynamic_faction_names.lua` | `dynamic_faction_decisions` |
| Ask Pope for Money decision and manual favour UI | `mechanics/pope/mechanics_pope_favour.lua` | `pope_favour_decisions` |
| Crusades and Pope UI listeners | `mechanics/pope/mechanics_pope.lua` | `pope_crusades_ui` |
| Pope capital visibility for human Catholic faction | `mechanics/pope/mechanics_pope.lua` | `pope_capital_visibility` |
| Religion conversion UI callback | `common/ui/mk1212_global_ui.lua` | `global_ui_religion_change` |

Manual kingdom/DFN/Pope decisions **require the common `decisions` feature**
to be active. When the matching opt-in is enabled, the corresponding
**automatic MP action is disabled for human-controlled factions** to
avoid executing both the manual and automatic action.

The England/France story event's co-op protection remains intentionally
untouched: its MP condition is not a simple missing SP feature.
`mk1212_slots.lua` hardcoded-limit changes remain blocked in MP.
An unused duplicate `mechanics_dynamic_faction_names.lua` at the campaign
root is not treated as active runtime authority.

Already initialized in ordinary MP (not new/opt-in): Byzantine, kingdoms, Mongol/Timurid,
nicknames, standard story; and Dynamic Faction Names, Islamic, Plague, Pope,
Settle Upkeep, Silk Road, War Weariness.

**Not exposed even through experimental flags:**
- `Ironman`: local autosave / quick-load / save naming, incompatible without a two-peer storage protocol.
- `Change Capital`: external native executable and local reload path; requires a separate redesign.
- Legacy `mk1212_networking` helper: intentionally disabled and without proof.

This list is **entrypoint inventory**, not a claim that every nested MP condition has been reviewed.
Run `python scripts/ci/audit_sp_mp_gates.py` to enumerate additional nested gates and
frontend-only access. Those findings require individual disposition. The scan is candidate
discovery and includes false positives from comments.

## One-switch FULL experimental smoke (unproven)

For an **isolated disposable dual-PC test only**, the registry also supports:
`enabled = true` plus `all_experimental = true`. This activates **every
known/wired experimental gate**, not Ironman, Change Capital, legacy networking,
or unsupported engine-only systems. Both .pack files MUST have identical bytes.
It is not safe for persistent saves and can crash/desync; the safe default is
both flags `false`.

The preferable approach is one feature at a time, not full smoke: keep
`all_experimental = false`, turn on `enabled = true`, and enable only
the feature flag and its required dependencies. Do not claim all SP behavior
is restored merely because registered listeners are active.

## Experimental usage — ONLY after fixing the named feature

1. Preserve a pristine working base campaign on each licensed PC.
2. For a disposable **new campaign**, set `enabled = true` and **one** feature flag
   to `true` in `campaigns/main_attila/mkmp_sp_parity.lua`.
3. Ship identical built `.pack` archives on BOTH computers. Verify SHA256,
   mod load order and exact Attila build. Never use per-peer/frontend local
   settings to pick shared-model features.
4. Obtain HOST and CLIENT evidence using `MK1212_mp_debug.log`,
   `twdll.log`, crash events and `scripts/ci/compare_mp_debug_logs.py`.
   A matching log is limited evidence, not proof of full engine determinism.
5. Test new campaign → first turn → faction cycle → battle (manual/autoresolve)
   → save/quit/reload → three rounds → forced edge case. Repeat.
6. Do not merge an enabled shared-model feature until exact-SHA both-peer
   evidence, deterministic event ordering, exactly-once and save stability are verified.
7. Return `enabled = false` after every test to restore the default behavior.

**Warning:** The switches are lab scaffolding and not a certificate of multiplayer safety.
Turning on an unreviewed flag is explicitly an unsafe experiment and may desync or
corrupt a disposable campaign. Never activate these flags on a valued save.

## CI source contracts
`python -m unittest discover -s scripts/ci -p "test_mp_*.py" -v`
asserts default MP remains fail-closed, verifies registered feature switches,
preserves the Ironman/change-capital/networking fences, and avoids SP frontend
feature selection for experimental MP.

No test in this branch substitutes for actual 2-PC Total War: ATTILA runtime proof.

## Follow-up queue

- Audit every `is_multiplayer` nested condition in gameplay Lua, plus `frontend` access.
- Assign each to one of: safe local presentation, shared-model mutation,
  saved shared state, local save/file operation, or engine/UX limitation.
- Introduce deterministic event ordering and one-shot operation IDs for
  buffer/annex/region-trade/occupation systems.
- Develop HRE, population and challenge-specific dual-peer simulation tests.
- Save-state and migration handling for each feature before enabling on an existing save.
- Exact two-PC proof with the DIAG2000 diagnostics bundle.
