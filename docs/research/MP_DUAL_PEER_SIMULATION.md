# MK1212 dual-peer simulation harness

Status: **CI-enforced repository proof**  
Issue: #28  
Runtime scope: no Total War: ATTILA process required  
Last reviewed: 2026-10-11

## Purpose

The final multiplayer proof still requires a real Attila session with two peers.

However, a large class of multiplayer failures can be detected earlier and more cheaply:

- peer-local configuration changing shared behavior;
- nondeterministic random decisions;
- non-canonical persistence;
- ambiguous delayed event correlation;
- lost deferred operations;
- optional native instrumentation accidentally becoming gameplay authority.

The dual-peer harness models those repository-level contracts in Python, checks source contracts, and executes selected production Lua modules in an isolated Lua 5.1 interpreter. These suites run on every CI change.

It does **not** emulate the entire Attila engine.

## Model

The harness creates two peers:

~~~mermaid
flowchart LR
    subgraph HOST["Fake HOST"]
        HLOCAL["local settings / local RNG / local native state"]
        HSHARED["shared campaign contract"]
        HLOG["shared mutation transcript"]
    end

    subgraph CLIENT["Fake CLIENT"]
        CLOCAL["different local settings / local RNG / local native state"]
        CSHARED["same shared campaign contract"]
        CLOG["shared mutation transcript"]
    end

    CONTRACT["Audited gameplay contract snapshot"] --> HSHARED
    CONTRACT --> CSHARED

    HLOCAL -. "must not alter shared decisions" .-> HSHARED
    CLOCAL -. "must not alter shared decisions" .-> CSHARED

    HSHARED --> HLOG
    CSHARED --> CLOG

    HLOG --> CMP{"Transcripts equal?"}
    CLOG --> CMP

    CMP -->|yes| PASS["CI PASS"]
    CMP -->|no| FAIL["CI FAIL at first divergence"]
~~~

A transcript contains only operations that conceptually affect shared campaign state.

Examples include create-force, character spawn, building-health mutation, vassalization and future treasury/diplomacy/model mutations added to the simulator.

The first mismatching operation is reported directly.

## Source binding

A simulation is useless if production Lua can silently drift away from it.

Therefore the CI suite has a second layer that inspects the real repository source.

Current source contracts include:

- zero active Lua math.random / math.randomseed in campaign runtime;
- heir age remains 16–30;
- Greek Fire damage remains 10–40;
- Mongol/Timurid spawn coordinates still use the deterministic boundary;
- normal multiplayer keeps experimental parity features off, and unsupported Ironman remains blocked;
- vassal reconciliation no longer depends on real-time vassal TimeTrigger callbacks;
- key/value save serializers still use canonical sorted keys and output budgets;
- deferred region transfer remains bounded and persisted;
- hardcoded-limit mutation remains blocked during an active multiplayer campaign;
- twdll remains optional and raw native battle addresses remain filtered;
- the old experimental MK1212 networking helper remains disabled.

This gives the CI proof three complementary surfaces: modeled scenarios, production-source contracts, and selected production Lua executed against controlled engine interfaces.

## Executing the production Lua

`scripts/ci/lua_test_runtime.py` compiles the committed sources under
`native/twdll/docs/lua/lua_source/src` into a temporary standalone interpreter.
The committed header identifies **Lua 5.1.2**, and its `luaconf.h` configures
`LUA_NUMBER` as **`float`**. Numeric round trips and timer-serial tests therefore
exercise that committed numeric configuration; they are not binary64 coverage.
This is a Lua compatibility test, not a claim about the exact VM build or numeric
configuration embedded in the user's Attila executable.
Missing compiler, build failure, Lua error, or failed fixture assertion fails the
test; there is no dependency download or silent skip.

The fixtures load the production modules with separate Lua environments for
HOST and CLIENT. They replace engine interfaces, event delivery, save storage,
and model command recording. They do not reimplement the tested gameplay or
serialization functions in Python.

| Production surface | Regression exercised | Test entry point |
| --- | --- | --- |
| Common persistence and RNG | Canonical schema-3 round trips; legacy literal preservation; malformed/unknown data and invalid RNG bounds/results; preserving the prior value on rejected writes | `scripts/ci/test_mp_core_runtime.py` |
| Population, decisions, nicknames persistence | Real feature save/load functions use the common codec and preserve their table shapes | `scripts/ci/test_mp_core_runtime.py` |
| War Weariness | Repeated initialization; divergent peer difficulty settings; repeated/reentrant faction turns; save/reload in the same phase; partial mutation failure; invalid battle result before either participant changes | `scripts/ci/test_mp_script_actions.py` |
| Mecca | Unique raze listener alongside Population; duplicate destruction suppression; saved faction key resolved after reload; real recapture allows another destruction; missing entities fail closed | `scripts/ci/test_mp_script_actions.py` |
| Buffer states | Captured region survives local selection changes; repeated confirmation, spawn callback and timer apply once; stale timer isolation; validated waiting-action restore; interrupted setup does not replay; ownership checks and serial exhaustion | `scripts/ci/test_mp_buffer_actions.py` |
| Unfinished Papal election UI | HOST-only vote-click placeholder refresh leaves shared RNG and election data unchanged; repeated refresh creates no additional logos | `scripts/ci/test_mp_ui_rng.py` |

The Papal election fixture directly invokes its unfinished handler. College of
Cardinals loading/initialization remains commented out in the campaign, so this
is a latent UI repair, not evidence of a currently active recruitment menu.
The Mecca tests cover the raze actor/listener lifecycle. A separate preexisting
ordinary-occupation refresh issue remains: a human faction turn removes Muslim
dejection effects and the already-occupied branch restores only the occupier's
outcry effect. This tranche does not claim to repair that path.

### Local difficulty is a documented synchronization boundary

**DOCUMENTED:** the official [Attila Extra Scripting Guides](https://wiki.totalwar.com/w/Total_War:_ATTILA_KIT_-_Extra_Scripting_Guides)
describe `MODEL_SCRIPT_INTERFACE.difficulty_level()` as the local faction's
difficulty. It is therefore not sufficient authority for a shared multiplayer
mutation. `MK1212_Campaign_Difficulty()` supplies the content-defined normal
baseline in MP and preserves the engine's selected difficulty in SP. War
Weariness tests deliberately give HOST easy and CLIENT legendary settings and
require equal shared model commands; separate SP cases retain both multipliers.

### War Weariness phase state

`MKMP_WW_TURN_SCHEMA = 1` and `MKMP_WW_LAST_TURN` are owned by the War Weariness
module. The payload stores one integer last-processed round per faction in
sorted-key order, with at most 4096 entries and 262144 bytes. It is separate from
the evolving common save codec. It never changes the meaning of the existing
weariness, event, or turns-at-war maps.

The turn claim is written before additive state or engine commands. A duplicate
callback, including a reentrant callback from a model command, cannot apply that
round twice. The claim survives save/load. If a command partially fails, the
handler does not retry already-applied work. This prevents duplicate mutations;
it does not repair a failed engine command.

Legacy saves without phase metadata start with an empty ledger. Loading itself
does not replay a turn; the next delivered faction-turn event records its own
completion. The script cannot reconstruct whether an old save had already seen
an unrecorded duplicate callback. Unknown schema, duplicate keys, impossible
turns, unknown factions, and malformed or oversized metadata stop passive turn
processing and retain the original metadata when saving. Battle/peace updates
are separate paths.

The fixtures prove these callback semantics in repository Lua. They do not prove
Attila event order, transport delivery, or that two peers executed an engine
command identically. In particular, repeated distinct battles involving the same
armies must not be collapsed into a faction/round token; battle-wide exactly-once
handling still needs a proven shared battle identity.

### Captured buffer-state action

The confirmation dialog captures region, master faction, intended vassal and
turn. A later selection change cannot replace those keys. Confirmation consumes
that intent before commands run, and only one pending action is allowed. The
existing `create_force` callback must return a valid CQI before vassal setup and
the delayed transfer are allowed. The callback claims its phase before model
commands, preventing a repeated callback from repeating setup.

Timers use `MK1212_Buffer_Transfer_<serial>` and may consume only the matching
`waiting_transfer` action. Serials are bounded at 1,000,000, which remains an
exact integer in the committed float configuration. Exhaustion refuses another
action rather than wrapping into an older timer name. Legacy `region_transfer`
events have no correlated target and cannot act on the current local selection.

`MKMP_BUFFER_ACTION_STATE` stores owned action schema 1 through the common codec:
one idle record or one seven-field action, with at most 4096 encoded bytes. Only
validated `waiting_transfer` metadata can resume, and first-tick initialization
checks the current region owner before arming a timer. The loading callback
issues no timer or model command. Saved `started`/`applying`/`blocked` phases,
malformed or future records retain their original payload and schema without
replaying a potentially partial spawn or vassalization. An already transferred
region completes as a no-op; a foreign owner blocks the action.

These fixtures exercise the production buffer/common Lua with controlled
engine callbacks and a counted vassal-tracker boundary. They prove the selected
local lifecycle contracts, including SP's existing direct-transfer path when a
vassal revives while the dialog is open. They do not synchronize a local click
between peers, provide a shared network action ID, emulate callback timing in
Attila, or compensate for a partially failed engine command. Buffer states
remain behind the experimental MP gate pending real two-peer evidence.

### Deferred plague timing question

The current plague countdown subtracts on `RegionTurnStart`; its historical
phase transitions already claim `PLAGUE_PHASE` before infection work. The
official event catalogue confirms the region context but does not establish
same-round ownership-change/reinfection delivery semantics. This tranche leaves
plague timing unchanged. A persisted region/round guard requires a targeted
runtime trace showing which repeat callbacks are duplicates and which follow a
new infection or ownership transition. No WH3 event semantics are assumed.

## Audited contract snapshot

**scripts/ci/mp_contracts.json** contains small, reviewable values inherited from the audited upstream gameplay contract.

Examples:

~~~text
heir age:              16..30
Greek Fire damage:     10..40
pending region queue:  max 64
save entry budget:     20000
save string budget:    1 MiB
vassal record max age: 1 turn
~~~

The contract snapshot records the upstream baseline SHA used during the audit.

Changing these values is a gameplay-contract change and must be reviewed as such; it is not a convenient way to make tests green.

## Dual-peer scenarios

### Local feature settings

HOST and CLIENT intentionally receive opposite local values for Challenges, Ironman and Lucky Nations.

Both must still resolve to:

~~~text
Challenges = OFF
Ironman = OFF
Lucky Nations = OFF
~~~

in multiplayer.

Hardcoded slot state is intentionally allowed to differ in the fake environment because the runtime policy is to observe/fingerprint it, not silently patch it after MP starts.

## Deterministic RNG

HOST and CLIENT use the same simulated campaign RNG seed and deliberately different local RNG seeds.

The local seeds must not influence shared state.

The harness exercises:

- heir creation;
- Greek Fire;
- Mongol spawning;
- Timurid spawning.

It also injects an invalid result such as:

~~~text
requested range: 16..30
engine result:    80
~~~

Expected behavior:

~~~text
fail before shared mutation
~~~

No invalid heir is written to the transcript.

## Save/output fuzzing

The serializer suite generates hundreds of maps with different insertion orders.

For logically identical state:

~~~text
HOST insertion order != CLIENT insertion order
~~~

the canonical serialized output must still be identical.

Covered shapes:

- string/number key-value maps;
- boolean maps;
- nested key/list maps;
- nickname-stat records.

It also requires:

- save→load→save stability;
- explicit empty nested lists remain explicit;
- over-budget writes fail before touching the last known-good value.

## Vassal event correlation

The simulator reproduces the hardened model:

- immutable liberation records;
- immutable subjugation records;
- immutable diplomacy records;
- sorted processing;
- bounded stale-state expiry.

HOST and CLIENT may observe the same semantic events in different arrival order.

They must still produce the same model transcript.

If two masters are plausible for one subjugation, the simulator must not guess.

~~~mermaid
flowchart TD
    S["Subjugation: V"] --> MATCH
    D1["Diplomacy: A -> V"] --> MATCH{"Unique matching proposer?"}
    D2["Diplomacy: B -> V"] --> MATCH

    MATCH -->|exactly one| APPLY["record vassalization"]
    MATCH -->|zero| WAIT["wait within bounded age"]
    MATCH -->|multiple| AMBIG["no mutation; expire safely"]
~~~

## Deferred region transfers

The harness verifies:

- multiple operations coexist;
- exact duplicates are suppressed;
- queue overflow fails before mutation;
- serialization/reload preserves order and content.

This protects the old crash workaround from regressing back into a one-slot lossy global.

## Native adapter fault injection

The fake native adapter tests:

- DLL missing;
- loader failure;
- capability missing;
- native call failure;
- different process-local native addresses.

All of these cases must leave the shared gameplay transcript unchanged.

For a ready adapter, battle addresses may differ:

~~~text
HOST battle pointer:   0x11111111
CLIENT battle pointer: 0xAAAAAAAA
~~~

while sanitized semantic telemetry can still match:

~~~text
cap=40
reinforcement queue=2
~~~

The address values are intentionally excluded.

## CI execution

The caller-local static lane runs:

~~~bash
python -m unittest discover -s scripts/ci -p "test_mp_*.py" -v
~~~

This requires Python and a C compiler (`cc` or `gcc`) from the normal Linux CI
environment. The Lua runtime is built from the repository's committed sources.

No game files, Steam login, Attila installation, GPU, DLL or second machine are required.

A simulator failure fails the caller-local static job and therefore propagates to the fail-closed Aggregate CI gate.

## What this proves

A green harness supports the claim:

> The checked repository preserves the modeled multiplayer safety contracts under deliberately divergent local inputs and randomized data ordering.

It can catch regressions such as:

- reintroducing Lua math.random;
- losing an MP feature gate;
- reintroducing timer-based vassal decisions;
- returning to unordered serializers;
- dropping pending region transfers;
- exposing native addresses as shared semantic data.

## What this does not prove

A green result is **not RUNTIME-PROVEN Attila multiplayer safety**.

It cannot prove:

- Attila event delivery order;
- engine lockstep implementation;
- actual cm:random_number equality on two clients;
- battle-to-campaign serialization behavior;
- vanilla river/bridge/coastal OOS bugs;
- current executable compatibility with twdll.

Those remain in the final real-runtime proof tracked by issue #15.

## Maintenance rule

When MP-sensitive production behavior changes, update both:

1. the production Lua code;
2. the relevant simulator/source contract.

Do not weaken the simulator or contract snapshot merely to obtain green CI.
