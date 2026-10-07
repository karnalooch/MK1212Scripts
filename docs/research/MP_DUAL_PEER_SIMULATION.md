# MK1212 dual-peer simulation harness

Status: **CI-enforced repository proof**  
Issue: #28  
Runtime scope: no Total War: ATTILA process required  
Last reviewed: 2026-10-07

## Purpose

The final multiplayer proof still requires a real Attila session with two peers.

However, a large class of multiplayer failures can be detected earlier and more cheaply:

- peer-local configuration changing shared behavior;
- nondeterministic random decisions;
- non-canonical persistence;
- ambiguous delayed event correlation;
- lost deferred operations;
- optional native instrumentation accidentally becoming gameplay authority.

The dual-peer harness models those repository-level contracts in pure Python and runs on every CI change.

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
- Challenges, Ironman and Lucky Nations remain hard-disabled by multiplayer runtime policy;
- vassal reconciliation no longer depends on real-time vassal TimeTrigger callbacks;
- key/value save serializers still use canonical sorted keys and output budgets;
- deferred region transfer remains bounded and persisted;
- hardcoded-limit mutation remains blocked during an active multiplayer campaign;
- twdll remains optional and raw native battle addresses remain filtered;
- the old experimental MK1212 networking helper remains disabled.

This gives the CI proof two independent surfaces:

~~~text
simulation contract
        +
production-source contract
        =
repository-level MP guard
~~~

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

This requires only Python from the normal repository CI environment.

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
