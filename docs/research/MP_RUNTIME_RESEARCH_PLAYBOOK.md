# Multiplayer, OOS and runtime research playbook

Status: canonical research workflow  
Issues: #3, #5  
Last reviewed: 2026-10-07

## Scope

Use this playbook for:

- MK1212 multiplayer desync/OOS investigations;
- determinism audits;
- battle-to-campaign transition problems;
- scripted event divergence;
- future concurrent-planning experiments;
- future simultaneous-turn feasibility research;
- any exact-build runtime instrumentation work.

## Principles

### Determinism before features

Do not build new multiplayer mechanics on top of unknown divergence.

Before simultaneous-turn work:

1. establish stable deterministic baseline;
2. remove known script-level nondeterminism in the tested path;
3. instrument state transitions;
4. obtain repeatable OOS/non-OOS results;
5. only then introduce concurrent behaviour.

### Detection point is not necessarily divergence point

An OOS message at end-turn or after battle proves only where the engine noticed disagreement.

Always search backwards for the first peer-to-peer state difference.

### Both peers are evidence

For MP-sensitive claims, one peer's log is incomplete evidence.

Minimum proof:

- same exact repo SHA;
- same game build;
- same mod set and load order;
- same initial save;
- synchronized trigger description;
- host log;
- peer log;
- observed result on both sides.

## Research phases

### Phase 0 — establish the environment

Record:

- Attila build/version;
- executable/module version or hash where practical;
- repository commit;
- enabled mods and load order;
- campaign/save provenance;
- factions and host/client roles;
- OS/Steam branch if relevant.

If any of these differ, mark the experiment BLOCKED until normalized.

### Phase 1 — source audit

Classify relevant code paths:

- DOCUMENTED;
- REPO-OBSERVED;
- CROSS-TITLE-REFERENCE;
- HISTORICAL-RE;
- COMMUNITY-REPORTED;
- HYPOTHESIS.

Audit for common MP hazards:

- Lua `math.random` in model-changing paths;
- local UI events leading to shared model changes;
- local-faction branches;
- unordered table iteration where operation order matters;
- asynchronous/time-trigger callbacks;
- non-persisted Lua state;
- save/load reconstruction gaps;
- callbacks that create forces/characters or alter diplomacy/economy;
- model changes executed on only one peer.

### Mandatory fragile-boundary matrix

The research catalogue identifies recurring fragile transitions. Treat these as first-class test targets:

- manual battle -> campaign restoration;
- autoresolve -> post-battle UI;
- river/bridge battle;
- coastal assault;
- siege battle;
- naval battle;
- faction turn end -> full AI cycle -> next human turn;
- invasion/world-event trigger;
- Papal/diplomacy transition;
- save -> quit -> reload -> continue.

A feature that touches one of these boundaries SHOULD add barrier logs immediately before and after its own mutation.

### Phase 2 — deterministic instrumentation

Prefer supported instrumentation first:

1. official Lua output/error logging;
2. deterministic structured log lines;
3. script event/context logging;
4. exact CQI/entity IDs;
5. state snapshots;
6. only later, exact-build runtime observation if the script surface is insufficient.

Recommended log schema:

```text
MKMP|seq=<n>|turn=<n>|phase=<phase>|faction=<key>|event=<name>|peer=<role>|cqi=<id>|token=<idempotence-token>|action=<name>|inputs=<stable values>|result=<stable values>|fingerprint=<hash>
```

For crash/resource investigations also record script-owned counters (tables/timers/spawns/UI children) and external process-memory telemetry when available. Do not label degradation as OOM without allocator/commit evidence.

Use a monotonically increasing deterministic sequence only where its increment semantics are themselves shared and proven.

### Phase 3 — force an early reproducer

Do not manually play dozens or hundreds of turns when a scripted trigger can be isolated safely.

For a dedicated test build:

- move trigger turn earlier;
- isolate one event;
- remove unrelated random branches;
- keep change clearly test-only;
- compare both peers immediately before and after the trigger.

Never confuse a test-only acceleration patch with the production fix.

### Phase 4 — state comparison

At important boundaries compare:

- turn number/current faction;
- treasury/economy if relevant;
- armies and CQIs;
- army positions;
- unit lists;
- character/family state;
- region ownership;
- building health/state;
- diplomacy;
- scripted timers/flags saved by MK1212;
- invasion/event state.

If a full engine checksum is unavailable, build targeted script-level fingerprints from stable shared state.

### Phase 5 — binary search the trigger

If divergence occurs inside a broad event:

1. instrument entry;
2. instrument before each model-changing call;
3. instrument deterministic inputs;
4. instrument immediate outputs;
5. disable half the branches;
6. repeat until the first differing operation is isolated.

### Phase 6 — apply scripting guardrails

Before implementing a fix, review `SCRIPT_SAFETY_GUARDRAILS.md`.

At minimum answer:

- what makes the operation deterministic?
- what proves exactly-once execution?
- what phase is safe?
- what entity validity checks fail closed?
- what state persists across save/load?
- what work/state budget prevents runaway growth?
- what both-peer evidence proves the result?

### Phase 7 — fix at the highest supported layer

Fix preference:

1. Lua logic/data;
2. official campaign/battle scripting API;
3. Assembly Kit/DB;
4. supported debug/log facilities;
5. exact-build instrumentation for diagnosis.

Runtime mutation is not the default fix path.

## Simultaneous-turn feasibility track

Treat this as a separate research program after sync stability.

Questions to answer in order:

1. What is the engine's authoritative concept of active turn faction?
2. Which checks are UI-only vs command/model enforcement?
3. Can a non-active local human faction issue any supported commands?
4. Which commands require active-faction ownership?
5. What happens if two human players target the same region/army?
6. Where is battle initiation serialized?
7. What is the safe round barrier before AI turns?
8. Which savegame fields encode active turn/round ownership?
9. Are command queues deterministic across peers?
10. Can "concurrent planning" be implemented without true concurrent model mutation?

### First milestone: concurrent planning

Before true simultaneous movement, target a safer model:

- both players can prepare plans/local UI state;
- shared model mutations are resolved in a deterministic barrier;
- conflicts are serialized;
- both peers apply the same ordered command set.

This can remove waiting time without requiring the engine to accept two fully active factions at once.

## Resource/OOM-like investigation rule

Read `ATTILA_CRASH_OOM_RESOURCE_HAZARDS.md`.

Use precise language:

- confirmed OOM only with allocation/commit evidence;
- resource pressure for workload/capacity stress;
- memory-leak-like only for progressive degradation that has not been measured;
- capacity-limit crash for count/roster threshold failures.

Long-session tests SHOULD sample both external process counters and script-owned counters.

## Success criteria for an OOS fix

A candidate fix is not accepted because "it worked once".

Minimum acceptance:

- exact-SHA build;
- deterministic reproducer before fix;
- reproducer fails before fix on demand;
- same scenario passes after fix;
- repeated runs;
- both-peer logs;
- no unrelated gameplay changes;
- save/load check when persistent state is involved;
- regression test or static guard where possible.

## Reporting format

Every research issue/PR should end with:

- **Claim**
- **Evidence tier**
- **Exact build/SHA**
- **Reproducer**
- **Before**
- **After**
- **Both-peer proof**
- **Known limitations**
- **Next experiment**

If evidence is incomplete, say BLOCKED or HYPOTHESIS.
