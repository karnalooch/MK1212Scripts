# ATTILA multiplayer stability failure catalogue

Status: canonical symptom/reproducer catalogue  
Issue: #5  
Last reviewed: 2026-10-07

## Purpose

This document records multiplayer/OOS/crash patterns reported for Total War: ATTILA and MK1212, and separates:

- **officially confirmed engine defects**;
- **repeatable community symptom reports**;
- **MK1212-specific reports**;
- **hypotheses that still require exact-build proof**.

Community reports are useful for prioritising reproductions. They are not root-cause proof by themselves.

## Evidence labels

- **DOCUMENTED** — official CA/SEGA patch/update documentation.
- **COMMUNITY-REPORTED** — forum/Steam/Reddit/TWC report.
- **REPO-OBSERVED** — visible in current MK1212 source.
- **RUNTIME-PROVEN** — reproduced on an exact build/configuration by this project.
- **HYPOTHESIS** — explanation not yet proven.
- **BLOCKED** — source/test unavailable.

## MP/OOS hazard matrix

| Hazard / boundary | Evidence | Typical symptom | What we can harden | Required proof |
| --- | --- | --- | --- | --- |
| battle -> campaign restoration | DOCUMENTED + COMMUNITY-REPORTED | OOS/crash after manual battle or post-battle UI | minimal transition-time UI, barrier logs, exactly-once result handling | both-peer pre/post fingerprints |
| autoresolve -> post-battle UI | DOCUMENTED | MP crash from popup before post-battle UI | defer optional UI; separate model/UI phases | exact-build autoresolve regression |
| river/bridge battle | COMMUNITY-REPORTED | repeatable battle desync | avoid extra script mutation; mandatory regression | vanilla-vs-modded A/B |
| coastal assault | COMMUNITY-REPORTED | battle desync | same; record naval/disembark state | repeated exact-save repro |
| siege/naval special paths | DOCUMENTED/COMMUNITY-REPORTED | crash/desync/pathing failure | no extra polling/UI/spawn pressure during battle transition | scenario-specific soak/repro |
| end-turn / AI cycle | COMMUNITY-REPORTED | desync/disconnect when cycling factions | state hash barrier, bounded per-turn work | both peers through full AI cycle |
| script event/invasion | REPO-OBSERVED + COMMUNITY-REPORTED | OOS after scripted mutation | deterministic RNG, one-shot token, spawn budget, save parity | forced-early reproducer |
| Papal/diplomacy transition | COMMUNITY-REPORTED | next-turn crash/desync | one-shot war/event guards, pre/post relation logs | dedicated Papal MP matrix |
| local UI -> shared mutation | DOCUMENTED risk + REPO-OBSERVED patterns | peer-only state change, crash | hard separation of UI intent/model mutation | identical peer event proof |
| mod/DLC/load-order mismatch | DOCUMENTED + COMMUNITY-REPORTED | different version, crash, hidden divergence | environment fingerprint; fail test setup closed | exact manifest equality |
| save/resync mismatch | COMMUNITY-REPORTED | resync helps temporarily or not at all | persisted-state audit, schema/version | replay same trigger after reload |
| stale local config | COMMUNITY-REPORTED | startup/campaign crash or divergent behaviour | local config isolation/version validation | config fingerprint |

## High-value official evidence

### MP crash: popup before post-battle UI

**Evidence:** DOCUMENTED  
**Source:** Total War Wiki, Garamantian Update (2016-02-25)  
https://wiki.totalwar.com/w/Garamantian_Update_(TWA).html

CA explicitly fixed:

- a Multiplayer Campaign crash caused by a popup appearing before the post-battle UI after auto-resolve;
- some Multiplayer Campaign crashes caused by UI panels;
- a UI crash caused by incidents having more than two payloads.

**Engineering implication:** the battle-result -> post-battle UI -> campaign transition is a proven fragile boundary. Scripted popups, panels and incidents must not be treated as harmless presentation when they are scheduled near this transition.

**Guardrail consequence:**

- do not inject nonessential popups during post-battle transition;
- queue UI work until a stable phase is proven;
- keep incident/message payloads minimal;
- instrument pre/post battle transition and UI delivery separately.

### MP/DLC mismatch crash and MP campaign script-state bug

**Evidence:** DOCUMENTED  
**Source:** Vengence of the Suebi Update / hotfix (2015-07-03)  
https://wiki.totalwar.com/w/Vengence_of_the_Suebi_Update_(TWA).html

CA fixed:

- crashes when MP players did not share The Last Roman ownership state;
- a Multiplayer Campaign script bug where the Roman Empire behaved as though the Roman Expedition had separated before it had actually done so.

The same patch also lists campaign AI lock-ups and battle AI crashes.

**Engineering implication:** apparently "external" environment differences and script phase/state errors can both become MP failure modes.

**Guardrail consequence:**

- fingerprint game/DLC/mod environment;
- never infer a state transition from intended chronology; query/validate actual state;
- fail closed when required faction/entity/state is absent.

### Family-tree / UI silent crash

**Evidence:** DOCUMENTED  
**Source:** Empires of Sand Update (2015-10-01)  
https://wiki.totalwar.com/w/Empires_of_Sand_Update_(TWA).html

CA fixed instances where the family tree silently crashed when opening the Faction tab.

**Engineering implication:** character/family mutations can surface later through UI access. A script that creates/changes family-tree state must be treated as high risk even when the mutation itself appears successful.

### Modern CPU crash fix

**Evidence:** DOCUMENTED  
**Source:** official Steam ATTILA update, 2023-07-04  
https://steamcommunity.com/app/325610/allnews/

The update:

- upgraded the compiler;
- fixed crashes on CPUs with more than 32 logical processors.

**Engineering implication:** exact executable/build and host hardware matter. Old runtime assumptions are invalid after engine updates even when mod Lua is unchanged.

### 2026 crossplay update

**Evidence:** DOCUMENTED for update; COMMUNITY-REPORTED for regressions  
**Source:** official Steam ATTILA update, 2026-09-17  
https://steamcommunity.com/app/325610/allnews/

CA shipped a cross-platform multiplayer update. The official note tells users to verify game files if issues appear.

Steam community pages subsequently surfaced user guides/reports claiming the update broke multiplayer for some configurations.

**Engineering implication:** MP proof is build-specific. Every test must record the exact live build, storefront/platform and whether the session crosses platforms.

## Vanilla ATTILA community symptom clusters

### Manual battle -> campaign map desync

**Evidence:** COMMUNITY-REPORTED  
**Steam (2015-03-26):**  
https://steamcommunity.com/app/325610/discussions/0/618457398961981259/

A co-op report describes desync after returning to the campaign map after any manually entered battle, regardless of win/loss/exit.

**Risk boundary:** battle state serialization, battle result application, post-battle UI, campaign state restoration.

### River/bridge battles repeatedly desync

**Evidence:** COMMUNITY-REPORTED, repeated on Steam and Reddit

Steam 2025:  
https://steamcommunity.com/app/325610/discussions/0/598518128651044640/

Reddit 2025:  
https://www.reddit.com/r/totalwar/comments/1il1jyk/

Reports describe near/fully repeatable desync during bridge/river battles in otherwise functional campaigns, including vanilla/no-mod attempts.

**Risk boundary:** special battle map/type, reinforcement/pathing/navmesh/battle-result state.

**Project rule:** maintain river/bridge as a mandatory regression scenario. Do not assume a script fix can eliminate an engine battle-type bug.

### Coastal assault desync

**Evidence:** COMMUNITY-REPORTED  
Same 2025 Steam/Reddit reports above.

A later campaign reproduced desync in a coastal city assault after other battles had worked.

**Risk boundary:** naval/coastal deployment, disembarkation, settlement battle transition.

### End-turn / AI-cycle disconnect/desync

**Evidence:** COMMUNITY-REPORTED

Steam 2015 — disconnect while cycling AI factions, reportedly after a large battle against Attila:  
https://steamcommunity.com/app/325610/discussions/0/617330406646309061/

Steam 2015 — deterministic turn 100 -> 101 desync near Hun AI turn, save exchange did not solve it:  
https://steamcommunity.com/app/325610/discussions/0/618457398973450128/

**Risk boundary:** deferred model work, AI faction processing, scripted turn-start/end work, accumulated campaign state.

**Project rule:** end-turn is a mandatory state-hash barrier. Detection at end-turn does not prove the divergence began there.

### Save sharing / resync is inconsistent

**Evidence:** COMMUNITY-REPORTED

Steam 2025 reports host-save sharing did not fix a battle desync:  
https://steamcommunity.com/app/325610/discussions/0/661592926180277588/

Reddit 2023 reports save exchange sometimes helps in Total War campaigns:  
https://www.reddit.com/r/totalwar/comments/1298276

**Interpretation:** save copying can re-align persisted state, but cannot repair a deterministic runtime path that re-diverges after load.

**Project rule:** never accept "host save fixes it" as root-cause proof.

## MK1212-specific evidence

### Early MP script desync reports

**Evidence:** COMMUNITY-REPORTED  
MK1212 Base Pack discussion, 2019-12-15:  
https://steamcommunity.com/workshop/filedetails/discussion/1429109380/3124866963982616641/

Report: MP campaign desync after turn 4; response says the multiplayer script was broken.

This is not authoritative root-cause analysis, but it establishes long-standing user-visible script instability.

### Community workaround: disable MK1212 scripts

**Evidence:** COMMUNITY-REPORTED  
RPG Co-op MK1212 workshop collection (2020):  
https://steamcommunity.com/workshop/filedetails/?id=2077302249

The collection notes that MK1212 scripts had to be disabled for multiplayer to work at that time.

**Implication:** scripts are a historically plausible causal layer, not only the Attila network engine.

### Actual MK1212 desync log at turn 7

**Evidence:** COMMUNITY-REPORTED with engine checksum text  
MK1212 Scripts discussion/comments, 2024:  
https://steamcommunity.com/workshop/filedetails/discussion/1934544571/4286937147066063770/

Reported log:

- `Campaign DESYNC DETECTED`;
- game tick 7253;
- detection at `CAMPAIGN_MODEL::advance_turn_after_all_end_turn_phases_handled`.

**Important:** this is the detection point, not proof that `advance_turn_after_all_end_turn_phases_handled` created the divergence.

### Frequent MP desync + Papal-State next-turn crash report

**Evidence:** COMMUNITY-REPORTED  
MK1212 Scripts comments:  
https://steamcommunity.com/sharedfiles/filedetails/comments/1934544571

A recent comment reports frequent multiplayer desynchronizations and a crash on the next turn after declaring war on the Papal States.

**Priority:** papal/diplomacy state transitions belong in the future deterministic reproducer matrix.

### Mod load order / version mismatch

**Evidence:** COMMUNITY-REPORTED / MOD-AUTHOR GUIDANCE  
MK1212 workshop discussions describe exact mod-set/load-order requirements and "different version" symptoms.

Examples:

https://steamcommunity.com/workshop/filedetails/discussion/1429109380/1729828401681630974/  
https://steamcommunity.com/workshop/filedetails/discussion/1934544571/3030299766080814520/

**Project rule:** MP tests are invalid unless mod list and load order match exactly.

### Save compatibility after script updates

**Evidence:** COMMUNITY-REPORTED  
MK1212 Scripts discussion, 2022:  
https://steamcommunity.com/workshop/filedetails/discussion/1934544571/3194741517062906011/

Users report old saves crashing after a script update.

**Project rule:** any change to persisted script state must declare save compatibility and migration/default behaviour.

### Config-state crash workaround

**Evidence:** COMMUNITY-REPORTED, mod-author response  
Steam 2020:  
https://steamcommunity.com/app/325610/discussions/0/2987539784427875803/

DETrooper suggested deleting `mk1212_config.txt`; users reported that this fixed crashes.

**Project rule:** local config must be treated as versioned external state. Invalid or stale config must fail safely and never silently affect shared campaign model.

## TWC evidence and retrieval limitation

Direct automated retrieval of `twcenter.net` forum pages is blocked in the current research environment. Do not fabricate content from inaccessible threads.

However, TWC Wiki and Steam pages expose indexed references:

- TWC Wiki lists **Attila - Custom Battle Crash Fix**:  
  https://wiki.twcenter.net/index.php?title=Total_War%3A_Attila_Mods
- Steam workshop page links to the TWC main thread and describes the same fix:  
  https://steamcommunity.com/sharedfiles/filedetails/?id=529522517
- The linked TWC thread ID surfaced by Steam is:  
  http://www.twcenter.net/forums/showthread.php?699714

The Steam description says Attila can crash in custom battle when an AI faction roster is larger than 70 units and many unit packs are installed.

**Evidence status:** COMMUNITY-REPORTED / secondary TWC reference, not direct thread verification.

## Required regression matrix

Every significant MP safety change should eventually exercise:

| Scenario | Why |
| --- | --- |
| autoresolve -> post-battle | official post-battle UI crash history |
| manual field battle -> campaign | repeated community OOS reports |
| river/bridge battle | repeated high-repro desync reports |
| coastal assault | repeated desync reports |
| siege battle | crash/desync/resource pressure surface |
| naval battle | separate battle-state path |
| end turn through full AI cycle | recurrent disconnect/desync boundary |
| invasion/event trigger | MK1212 script-heavy mutation |
| diplomacy declaration involving Papacy | specific MK1212 report |
| save -> quit -> reload -> continue | persistence parity |
| host-save resync -> replay trigger | distinguish persisted vs runtime divergence |
| old-save compatibility test | script-state migration risk |

## What this catalogue does not claim

It does not claim:

- every river/bridge battle always desyncs;
- all long-session crashes are OOM;
- all MK1212 MP failures are script-caused;
- the Papal-State report has a proven root cause;
- save sharing is a fix;
- any historical TWC workaround applies to the current build.

The job of this catalogue is to turn recurring reports into reproducible test targets and defensive design rules.
