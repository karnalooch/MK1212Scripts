# MK1212 multiplayer and runtime scripting guardrails

Status: normative safety specification  
Issue: #5  
Last reviewed: 2026-10-07

Normative terms **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, **MAY** are intentional.

## Safety model

A script feature is not safe merely because it works in single-player.

For multiplayer-sensitive code we care about five invariants:

1. **determinism** — peers compute the same inputs/results;
2. **exactly-once mutation** — a shared mutation is not duplicated;
3. **phase safety** — mutation happens in a stable campaign/battle phase;
4. **bounded work/state** — no runaway listeners/timers/tables/UI/spawns;
5. **persistence parity** — save/load reconstructs the same state on all peers.

## G1 — deterministic randomness

### MUST

- Shared-model randomness MUST use a mechanism proven deterministic for Attila MP.
- Random result, inputs and trigger identity MUST be loggable.
- Random draws that affect shared state MUST occur in a deterministic order.

### MUST NOT

- use Lua `math.random()` for campaign/battle model mutation;
- use `math.randomseed`, `os.time`, `os.clock` or wall-clock/environment-derived entropy for shared state;
- perform a different number of random draws on different peers.

### Legacy debt

Existing unsafe uses are baseline technical debt. CI blocks **new** obvious nondeterministic sources while legacy sites are removed deliberately.

## G2 — exactly-once model mutation

Every high-impact mutation SHOULD have an idempotence token.

Suggested token:

```text
<feature>|<turn>|<phase>|<faction>|<entity>|<operation>
```

Examples of high-impact mutations:

- create/spawn force;
- spawn character/family member;
- change region ownership;
- apply/remove persistent bundle;
- change diplomacy;
- change building health;
- kill/replace character;
- alter treasury/population;
- start invasion/world event.

### MUST

- prove whether the listener can run once per faction, once per human, once per round or once globally;
- guard intended one-shot work explicitly;
- record completion state before any retry path can re-enter.

### MUST NOT

- silently retry a partially successful model mutation;
- assume "listener usually fires once".

## G3 — listener registration

### MUST

- listener IDs MUST be globally unique;
- initializers MUST be safe against duplicate invocation;
- removal/re-registration lifecycle MUST be explicit for temporary systems.

### SHOULD

Maintain listener ownership by feature/module.

### Failure mode

Duplicate listeners can create duplicated model mutations while logs still look superficially valid.

## G4 — timer/callback lifecycle

### MUST

Every recurring timer/callback declares:

- owner;
- trigger name;
- start condition;
- stop condition;
- maximum active instances;
- minimum interval;
- whether it survives save/load.

### MUST NOT

- create unowned infinite polling loops;
- schedule zero-delay recursive work without a bounded reason;
- start a second recurring timer if one is already active for the same owner.

### SHOULD

Prefer campaign events over polling.

## G5 — UI/model separation

Official Attila patch history proves UI ordering can crash Multiplayer Campaign.

### MUST

- local UI events are treated as local until proven network-safe;
- UI handlers MUST NOT directly mutate shared model unless the execution semantics are proven identical on all peers;
- post-battle transition MUST NOT be cluttered with nonessential scripted popups/panels.

### SHOULD

Split code into:

1. local presentation/intent;
2. validated shared mutation.

### High-risk events

Treat these as synchronization boundaries:

- `ComponentLClickUp`;
- `CharacterSelected`;
- `SettlementSelected`;
- panel opened/closed events;
- post-battle UI;
- dilemma/incident UI callbacks.

## G6 — transition barriers

Mandatory instrumentation targets:

- before battle launch;
- battle result available;
- before post-battle UI;
- after campaign restoration;
- faction turn start;
- faction turn end;
- before/after full AI cycle;
- save;
- load.

At each barrier, log a compact shared-state fingerprint when the feature under test affects that state.

## G7 — entity validity / fail closed

Before mutating an entity:

- verify faction exists and is not null;
- verify character/CQI exists;
- verify force exists;
- verify region/slot/building exists;
- verify expected ownership/state;
- verify the operation still makes semantic sense.

If a required entity is missing:

- emit diagnostic;
- skip mutation;
- do not substitute a random/default target unless the design explicitly defines one deterministically.

## G8 — spawn budgets

Every feature that creates forces/characters MUST declare a budget.

At minimum:

- max per trigger;
- max per faction turn;
- max per round;
- retry policy.

Budget breach MUST fail closed.

A recovery system MUST NOT spawn indefinitely because AI keeps losing forces.

## G9 — bounded state

Every long-lived table MUST have:

- schema/meaning;
- maximum expected size;
- cleanup trigger;
- stale-entry validation;
- persistence decision.

Examples:

- CQI -> metadata maps;
- applied bundle timers;
- event history;
- raid/region trackers;
- spawned force registries.

Tables keyed by dead CQIs MUST be pruned.

## G10 — save/load parity

### MUST

Any Lua state that can alter future shared model mutation MUST be either:

1. persisted; or
2. deterministically reconstructible from game state.

### MUST

- defaults are identical on all peers;
- save keys are stable and documented;
- serialization has a schema/version when structure can evolve;
- load sanitizes impossible/duplicate entries.

### MUST NOT

- derive shared state from local config during load;
- silently ignore malformed persisted state and continue with random fallback.

## G11 — serialization budgets

String/table save formats MUST be bounded.

Avoid:

- unbounded concatenation;
- duplicate records;
- state history when only current state is needed.

On oversized/invalid state:

- log;
- fail the feature closed;
- preserve the campaign if possible without applying duplicate mutations.

## G12 — config/environment isolation

Local files such as `mk1212_config.txt` are not shared campaign authority.

### MUST NOT

Let a local-only setting change shared campaign model in MP unless:

- both peers' value is fingerprinted and verified identical; or
- the value is transferred through a proven shared mechanism.

### MUST

MP proof records:

- Attila build;
- storefront/platform;
- repo SHA;
- mod list;
- load order;
- DLC relevant to scenario;
- local config fingerprint;
- host/client role.

## G13 — ordered iteration

Lua table iteration with `pairs()` MUST be treated as unordered.

If iteration order affects:

- RNG draw order;
- mutation order;
- target selection;
- serialized output;
- hashes;

then keys MUST be sorted or a deterministic ordered structure used.

## G14 — post-battle safety

Because CA fixed MP crashes related to post-battle popup/UI ordering:

### MUST

- keep post-battle mutation sequence minimal;
- separate model mutation from optional UI;
- avoid new popups before stable post-battle UI completion unless exact-build proof exists;
- log battle ID/context, attacker/defender CQIs and result before and after feature logic.

## G15 — diplomacy/Papacy safety

Given MK1212 community reports around Papal-State war transitions:

Any new Papal/diplomacy feature MUST:

- log pre/post relation/war state;
- use one-shot transition guards;
- avoid triggering the same war/dilemma/incident from multiple listeners;
- test declaration, peace, vassal/alliance interactions, and next-turn processing in MP.

This is a priority reproducer, not a proven root cause.

## G16 — invasion/world-event safety

Invasions combine high-risk operations: RNG, force creation, diplomacy, timers and messages.

### MUST

- use deterministic RNG;
- cap force creation;
- compute spawn coordinates deterministically;
- ensure event fires once globally at intended phase;
- validate target regions;
- persist "started/completed" flags;
- log each created force/CQI;
- delay optional UI until model changes are complete.

## G17 — resource budgets

Every new subsystem SHOULD state budgets for:

- listeners;
- timers;
- table entries;
- spawned entities;
- UI children;
- save data;
- logging rate.

No subsystem may rely on "this should never grow that large."

## G18 — no unsafe fallback

A fallback is dangerous when it changes the model differently across peers.

MUST NOT:

- choose first available target from unordered data;
- choose a random substitute;
- silently retry with different coordinates/entity;
- use local faction/UI state as substitute for missing shared state.

Fail closed and report.

## G19 — proof requirements

A MP safety fix is accepted only with:

- exact game build;
- exact repository SHA;
- exact mod/load order;
- deterministic reproducer before fix where possible;
- repeated after-fix runs;
- both-peer logs;
- barrier fingerprints;
- save/load check if state persists.

Special regression scenarios:

- manual field battle;
- river/bridge;
- coastal assault;
- siege;
- autoresolve;
- full AI/end-turn cycle;
- invasion;
- Papal diplomacy;
- save/reload.

## G20 — static CI policy

CI MUST reject new obvious nondeterminism in runtime Lua.

At minimum new additions of these patterns are forbidden:

- `math.random`;
- `math.randomseed`;
- `os.time`;
- `os.clock`.

CI SHOULD report (initially warning/advisory) new additions involving:

- `pairs(`;
- `cm:add_time_trigger`;
- `cm:create_force`;
- `spawn_character`;
- `CreateComponent`;
- UI-selection/click listeners;
- direct building/region/diplomacy mutation.

Warnings are not proof of a bug; they force review.

## Implementation direction

Future runtime hardening should introduce shared helpers rather than ad-hoc checks:

```text
mkmp.guard_once(token)
mkmp.require_entity(...)
mkmp.safe_random(...)
mkmp.spawn_budget(...)
mkmp.timer_register(...)
mkmp.state_fingerprint(...)
mkmp.log_event(...)
```

Names are provisional. Semantics must be documented and tested before adoption.

The goal is not "more wrappers." The goal is to make unsafe mutation difficult to express accidentally.
