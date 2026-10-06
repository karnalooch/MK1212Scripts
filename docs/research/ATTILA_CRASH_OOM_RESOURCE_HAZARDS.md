# ATTILA crash, OOM-like and resource-pressure hazards

Status: canonical resource-risk model  
Issue: #5  
Last reviewed: 2026-10-07

## Terminology: do not overclaim OOM

Use these terms precisely.

### Confirmed OOM

Use **OOM** only when there is direct evidence such as:

- allocator/out-of-memory error;
- crash dump showing allocation failure;
- measured process/commit exhaustion;
- engine diagnostic explicitly identifying memory exhaustion.

We do not currently have project-owned evidence proving a general Attila OOM defect.

### Resource pressure

Use when workload size is plausibly stressing memory/CPU/GPU/engine limits, regardless of final crash cause.

### Memory-leak-like degradation

Use for community reports where performance worsens across a long session and improves after restart.

This is a **symptom description**, not proof of a leak.

### Capacity-limit crash

Use when a repeatable content-count threshold or engine limit is reported.

## Official engine/environment hazards

### >32 logical processor crash

**Evidence:** DOCUMENTED  
Official ATTILA update, 2023-07-04:  
https://steamcommunity.com/app/325610/allnews/

CA fixed game crashes on CPUs with more than 32 logical processors and upgraded the compiler.

**Lesson:** engine stability depends on host environment and exact build. A "random crash" may be unrelated to our Lua.

### Campaign/battle AI lock-ups and crashes

**Evidence:** DOCUMENTED  
Vengence of the Suebi Update:  
https://wiki.totalwar.com/w/Vengence_of_the_Suebi_Update_(TWA).html

CA fixed campaign AI lock-ups, battle AI crashes and settlement-graph-related crash cases.

**Lesson:** scripts should avoid adding repeated work or malformed state around already complex AI phases.

### Family tree / Faction UI crash

**Evidence:** DOCUMENTED  
Empires of Sand Update:  
https://wiki.totalwar.com/w/Empires_of_Sand_Update_(TWA).html

Family-tree state could trigger a later silent UI crash.

**Lesson:** character/family mutation requires validity checks and save/load parity.

## Community resource-pressure reports

### Long sessions become increasingly slow around battle transitions

**Evidence:** COMMUNITY-REPORTED  
Steam 2024:  
https://steamcommunity.com/app/325610/discussions/0/4334230932331804906/

A user reports 10-12 hour sessions with roughly 100-150 manual battles becoming increasingly slow when loading into/out of battles and sometimes crashing.

**Classification:** memory-leak-like degradation; root cause unproven.

### Battles becoming slower after the first few

**Evidence:** COMMUNITY-REPORTED  
Reddit 2020:  
https://www.reddit.com/r/totalwar/comments/h7qgt9

User describes later battles running markedly slower than early battles in the same session.

**Classification:** performance degradation; "memory leak" is the user's hypothesis, not proof.

### Large siege/battle crash reports

**Evidence:** COMMUNITY-REPORTED  
Reddit 2026 siege report:  
https://www.reddit.com/r/historicaltotalwar/comments/1sn5cwg/siege_battle_crash_atilla/

A user describes a roughly 4,000 vs 9,000 town battle that suffered severe frame drops and later crashed.

**Classification:** large-battle resource pressure; no proven OOM mechanism.

### VRAM reporting/limit workarounds

**Evidence:** COMMUNITY-REPORTED  
Steam discussions:  
https://steamcommunity.com/app/325610/discussions/0/618453594764752203/  
https://steamcommunity.com/app/325610/discussions/0/2828702372998099128/

Attila users report VRAM detection/reporting limits and preference-script workarounds.

**Classification:** graphics resource/configuration hazard, not proof of system-memory OOM.

### Custom battle roster capacity

**Evidence:** COMMUNITY-REPORTED / TWC-linked  
Steam:  
https://steamcommunity.com/sharedfiles/filedetails/?id=529522517  
TWC Wiki:  
https://wiki.twcenter.net/index.php?title=Total_War%3A_Attila_Mods

The Attila Custom Battle Crash Fix description reports a crash when AI uses a faction roster larger than 70 units with many unit-pack mods.

**Classification:** capacity-limit crash.

**Lesson:** content cardinality itself can be a crash vector.

## Script patterns that can amplify resource pressure

Even if the engine owns the underlying memory/performance problem, Lua can make it worse.

### Unbounded tables

Hazards:

- appending CQIs/events forever;
- never removing dead entities;
- retaining per-turn history for the whole campaign;
- duplicating entries across load.

**Rule:** every long-lived table needs:

- owner;
- key semantics;
- cleanup event;
- maximum expected cardinality;
- save policy.

### Unbounded serialization

Hazards:

- concatenating arbitrary table contents into one save string;
- repeated delimiters without schema/version;
- duplicated entries after load;
- no maximum entry count.

**Rule:** serialization must be bounded and versioned.

### Timer storms

Hazards:

- recurring `add_time_trigger` loops with no owner/cancel path;
- zero/near-zero intervals;
- registering the same timer from multiple listeners;
- timers surviving state changes that make their work irrelevant.

**Rule:** recurring work requires a lifecycle guard and one active instance per logical owner.

### Duplicate listener registration

Hazards:

- initializer called twice;
- load/new-game path both registering same semantic listener under different names;
- callbacks firing twice and duplicating model mutation.

**Rule:** listener names are globally unique and registration is idempotent.

### Repeated UI component creation

Hazards:

- `CreateComponent` on every open/refresh without destroying/reusing;
- random or unbounded child counts;
- UI retained across state changes.

**Rule:** component creation has an explicit upper bound and cleanup/reuse strategy.

### Spawn storms

Hazards:

- repeated `create_force` or character spawning inside callbacks;
- retry-on-failure without mutation receipt;
- multiple peers independently deciding to spawn;
- trigger firing once per human/faction when intended once per round.

**Rule:** every spawn path has a deterministic event token and per-event/per-turn budget.

### Full-world high-frequency scans

Hazards:

- scanning all factions/characters/regions every tick;
- polling instead of listening to relevant campaign events;
- combining scans with string logs/UI work.

**Rule:** event-driven logic is preferred. Polling requires a documented frequency and cost budget.

### Log floods

Hazards:

- per-frame/per-tick logging;
- huge state dumps every event;
- non-rotated external logs.

**Rule:** structured logs are bounded; high-volume traces are opt-in test instrumentation.

## Resource budgets for future runtime code

These are design requirements, not yet engine-tuned numeric limits.

Every new long-lived system MUST declare:

- max active listeners it owns;
- max recurring timers it owns;
- max table entries retained across turns;
- max entities spawned per trigger and per turn;
- max UI components created per panel/open;
- max serialized entries/bytes per save field where measurable;
- cleanup phase;
- fail behaviour when the budget is exceeded.

Default fail behaviour: **skip mutation and emit a diagnostic**, not "try again until it works."

## OOM/resource-pressure telemetry plan

When runtime instrumentation is added, capture:

- process private bytes / working set if available externally;
- commit usage;
- GPU memory if practical;
- number of active script-owned table entries;
- number of active timers/listeners;
- number of script-created forces/characters;
- log size/rate;
- transition timing for campaign -> battle and battle -> campaign.

A confirmed memory leak requires a reproducible growth pattern where retained memory/state does not return after expected cleanup.

## Long-session soak test

For resource-sensitive changes, plan a soak lane:

1. start from exact save/build;
2. capture baseline process/script counters;
3. execute repeated battle/campaign transitions;
4. include at least one siege and one coastal/river special case;
5. sample counters every N transitions;
6. restart the game and compare;
7. distinguish engine growth from script-owned growth.

Do not use "it ran for two hours" as proof of absence of a leak.

## What our scripts can and cannot fix

We **can**:

- prevent duplicate work;
- bound our own tables/strings/UI;
- avoid spawn storms;
- avoid high-frequency polling;
- clean stale CQIs/state;
- reduce risky transition-time UI work;
- log resource counters.

We **cannot** guarantee:

- engine allocator correctness;
- battle renderer stability;
- navmesh stability;
- network stack stability;
- driver/CPU compatibility;
- removal of vanilla river/coastal desync bugs.

The purpose of script hardening is to avoid adding pressure and make failures diagnosable.
