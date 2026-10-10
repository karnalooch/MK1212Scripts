# MK1212: SP → MP parity experiment — Issue #66

Status: **DRAFT, opt-in only / NO REAL-GAME MP PROOF** (2026-10-10).
Authority: `AGENTS.md`, `SCRIPT_SAFETY_GUARDRAILS.md`, `MP_RUNTIME_RESEARCH_PLAYBOOK.md`.

## Intent
Expose functionality present in a single-player campaign but withheld in multiplayer,
on two physical PCs with distinct **licensed Steam accounts**. Never use Goldberg or
Sandboxie as the multiplayer proof environment. The original game binary remains unchanged.

The code in this branch **does not turn everything on by default**.
All existing SP behavior and the tested baseline MP guard behavior are preserved.

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
