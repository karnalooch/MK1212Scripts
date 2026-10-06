# MK1212 multiplayer final validation plan

Status: **READY TO EXECUTE AFTER IMPLEMENTATION BACKLOG CLOSES**  
Issue: #15  
Runtime execution: intentionally deferred  
Last updated: 2026-10-07

## Rule

Do not run piecemeal Attila multiplayer tests while the implementation backlog is still changing.

The validation campaign starts only after the code tasks are merged, so every result refers to one exact candidate build.

## Required evidence header

Every host/client log bundle must record:

```text
Attila build:
Storefront/platform:
MK1212Scripts commit:
twdll commit/build SHA:
mod list + load order:
hardcoded-limits fingerprint:
host faction:
client faction:
save provenance:
proof schema:
```

## Harness

The repository provides:

- `common/mkmp_runtime.lua` — optional twdll adapter and semantic campaign fingerprint;
- `common/mkmp_proof.lua` — read-only event/barrier log harness.

The proof harness logs:

- human faction turn start/end;
- pending battle;
- battle complete;
- dilemma choices;
- post-battle actions;
- war declarations;
- faction-leader changes;
- explicit proof-only time triggers;
- compact semantic campaign fingerprints.

Raw native memory addresses are deliberately excluded.

## Pass rule

For a barrier expected to be shared:

```text
HOST seq/event/detail/fingerprint
CLIENT seq/event/detail/fingerprint
```

must have equivalent event semantics and matching campaign fingerprint.

A later Attila OOS message is not the primary metric. The first mismatching proof barrier is.

## Phase A — baseline

1. both peers launch the exact same build/mod set;
2. record environment fingerprints;
3. start a fresh MP campaign;
4. verify human-faction ordering;
5. advance two full rounds without special scripted events;
6. save;
7. quit both peers;
8. reload;
9. advance one more round.

## Phase B — deterministic RNG

Force/accelerate in a dedicated test build only:

1. old ruler with no heir;
2. Greek Fire explosion;
3. Mongol invasion;
4. Mongol replenishment;
5. Timurid invasion;
6. Timurid replenishment.

Compare fingerprints immediately before/after every draw-driven mutation.

## Phase C — local configuration mismatch

Deliberately give peers conflicting local values for:

- challenge flags;
- Ironman;
- Lucky Nations;
- hardcoded-slot state.

Expected:

- Challenges/Ironman/Lucky Nations resolve to the same MP runtime state regardless of local SVR.
- Hardcoded slot mismatch is visible in the environment fingerprint and no in-session patch is executed.

## Phase D — vassal tracking

Exercise:

1. liberation resulting in alliance;
2. liberation resulting in vassal relationship;
3. direct subjugation;
4. multiple diplomatic events close together;
5. save/reload with pending operation records.

No operation may be guessed from ambiguous event correlation.

## Phase E — persistence

Use a save with representative state in:

- Papal favour;
- War Weariness;
- vassal tracking;
- nicknames;
- plague;
- dynamic faction names;
- invasion upkeep records;
- deferred region transfer.

Compare semantic state before save and after reload.

## Phase F — historically fragile engine boundaries

Run:

- manual field battle -> campaign;
- autoresolve -> post-battle;
- river/bridge battle;
- coastal assault;
- siege;
- full end-turn AI cycle;
- Papal war/post-battle flow;
- active story dilemma.

Separate vanilla-engine failures from script-state divergence.

## Phase G — event semantics requested by #15

Prove on both peers:

- `DilemmaChoiceMadeEvent`;
- `CharacterCompletedBattle`;
- post-battle release/slaughter/enslave;
- secondary-general battle callbacks where applicable;
- proof-only `TimeTrigger`;
- `cm:random_number`/random-percent result parity;
- faction list / human player ordering;
- Pope changeover;
- story dilemma mutation;
- Starting Battle round trip.

## Failure handling

When a mismatch appears:

1. stop advancing the campaign;
2. preserve both logs and the triggering save;
3. record the first mismatching sequence;
4. compare the event immediately before it;
5. reproduce from the saved boundary;
6. do not "fix" by exchanging saves until the divergence source is captured.

## Acceptance

Final MP hardening is accepted only when:

- implementation issues are closed;
- baseline/save-load pass;
- all P0 repro scenarios pass repeatedly;
- no peer-local setting changes shared feature activation;
- first-divergence instrumentation works;
- known vanilla Attila failure modes are documented separately from MK1212 failures.
