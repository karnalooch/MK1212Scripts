# Total War: ATTILA Assembly Kit and scripting authority

Authority class: **DOCUMENTED / Tier A**  
Primary source: https://wiki.totalwar.com/w/Assembly_Kit_(TWA).html  
Last reviewed: 2026-10-06

## Role

The ATTILA Assembly Kit is the highest-priority public source for what Creative Assembly officially exposed to modders. For this repository, supported solutions should be preferred over runtime patching whenever the Assembly Kit or scripting layer can satisfy the requirement.

## Official tool surfaces

The Assembly Kit page identifies four major tools.

### DaVE

Purpose: database editing.

Use DaVE authority when work concerns game database entries, table-driven content, balancing data, record keys, junctions, effects, units, buildings or related DB structures.

Repository implication: changes under `db/` should be reasoned about primarily through Attila DB/Assembly Kit semantics, not through reverse-engineered memory structures.

### BOB

Purpose: processing raw data such as textures, models and animations.

Use BOB authority for asset processing and pack-oriented build steps that are part of the official content pipeline.

BOB is not evidence for multiplayer synchronization or campaign command ordering.

### TeD

Purpose: creation of battlefields for land, sea and siege battles.

Use TeD authority for battlefield content and battle-map authoring.

TeD does not establish that a modern WH3 battle scripting method exists in Attila.

### Terry

Purpose: campaign-map aesthetics and terrain authoring. The official page specifically notes access to Terrain Raw Data and the ability to influence which battle maps load for campaign-map locations.

Use Terry authority for map/terrain composition and battle-catchment style questions.

## Official ATTILA scripting expansion

The Assembly Kit page links to ATTILA scripting documentation. These linked official pages extend Tier A authority:

- Scripting index:  
  https://wiki.totalwar.com/w/Total_War%3A_ATTILA_Kit_Scripting.html
- Environment settings:  
  https://wiki.totalwar.com/w/Total_War%3A_ATTILA_KIT_-_Environment_Settings
- Battle script documentation:  
  https://wiki.totalwar.com/w/Total_War%3A_ATTILA_KIT_-_Battle_Script_Documentation
- Campaign script interface:  
  https://wiki.totalwar.com/w/Total_War%3A_ATTILA_KIT_-_Campaign_Script_Interface
- Extra scripting guides / events and interfaces:  
  https://wiki.totalwar.com/w/Total_War%3A_ATTILA_KIT_-_Extra_Scripting_Guides

## Logging and debug environment

The official Environment Settings guide describes a supported debugging setup for scripted battle work.

Relevant capabilities include:

- enabling debug UI through user preferences;
- Lua error logging;
- Lua output logging;
- battle XML logging;
- debug UI that exposes useful camera/cursor information.

Engineering rule: before inventing an external runtime hook merely to observe script state, first verify whether official Lua logging, debug UI, event callbacks or script interfaces can provide the needed evidence.

## Campaign interfaces that matter to multiplayer research

The official ATTILA scripting pages expose concepts directly relevant to multiplayer and OOS investigations, including:

- `is_multiplayer()`;
- `is_player_turn()`;
- `faction_is_local(...)`;
- faction/character/military-force lookup by command queue index;
- campaign event contexts such as `FactionTurnStart`, `FactionTurnEnd`, `CharacterSelected`, `RegionRebels`, `DilemmaChoiceMadeEvent` and battle/campaign events.

These are important because MK1212 frequently binds model-changing logic to events.

### Interpretation rule

The existence of an event or query does **not** prove that every command called from its listener is network-replicated or multiplayer-safe.

For each listener, distinguish:

1. event delivery semantics;
2. local-vs-shared state read;
3. command/model mutation;
4. deterministic inputs;
5. save/load persistence;
6. multiplayer replication behaviour.

## Battle scripting authority

The official ATTILA battle documentation describes Lua-driven battle control through an Attila battle object model. That establishes a supported battle scripting lane.

However, the exact object names and function sets in modern WH3 documentation must not be projected backwards into Attila.

If a capability is needed:

1. search official ATTILA battle docs first;
2. inspect existing Attila scripts/examples;
3. test on the exact Attila build;
4. only then use a WH3 pattern as inspiration for a compatibility shim or equivalent instrumentation.

## Known documentation caveat

The official Campaign Script Interface page itself warns that some material is old and may have degraded or no longer work correctly.

Therefore even Tier A documentation may require runtime confirmation for edge cases.

That does **not** reduce it below cross-title references; it means the correct status is:

- DOCUMENTED, then
- RUNTIME-PROVEN or RUNTIME-REJECTED for the exact build.

## Preferred implementation order

For any new capability:

1. existing MK1212 Lua/content;
2. documented Attila script API;
3. documented Assembly Kit data/tooling;
4. supported logging/debug features;
5. exact-build runtime experiments;
6. cross-title design references;
7. historical reverse-engineering hints.

Do not start at step 7 because it looks powerful.
