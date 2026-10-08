# twdll function-level distribution and SEGA/CA compliance audit

Status: **SOURCE-OBSERVED / RELEASE BLOCKED FOR NATIVE**  
Date: 2026-10-08  
Repository: `karnalooch/MK1212Scripts`, branch `feat/44-mk1212-twdll-runtime-integration`  
Tracking: #60 (publisher compliance), #40 (native safety), #44 (runtime integration), #48 (AEEF architecture).

## Purpose and important distinctions

This is an **engineering/compliance risk inventory**, not a legal opinion, publisher authorization or finding of illegality. The existence of source code does not prove a particular function ran in MK1212. SEGA's rights in Total War: Attila are separate from GPL-3.0 rights in twdll. No ban probability can be inferred from this source audit.

Working categories:
- **R — read-only semantic getter**: intended to report existing state, but implementation may still depend on invasive initialization hooks.
- **M — game-state mutation**: changes campaign/battle entities, persistence, balance, AI, or engine state.
- **U — user interface / visual mutation**: changes displayed state or UI behavior; still subject to permission/compatibility review.
- **H — hook / runtime binary intervention**: hooks, trampolines, page permission changes, or instruction writes. This is the highest review-priority implementation lane.
- **E — execution/lifecycle control**: save, load, exit and other host execution side effects.
- **? — needs call-graph and source inspection**: classification based on symbol alone is insufficient.

**R does not mean “approved by SEGA.”** Read-only functions implemented via process hooks may still have elevated terms/compliance risk. **A new C++ capability is not automatically publishable because it is GPL-licensed.**

## Confirmed native intervention points

| File / symbol | Source-observed mechanism | Class | Release recommendation |
|---|---|---|---|
| `src/attila/world.cpp` / `install_world_hook` | `MH_CreateHook`, `MH_EnableHook`, constructor trampoline and cached `g_world` pointer | H | Native experiment only; publisher/legal review before public distribution |
| `src/attila/world.cpp` / `set_reinforcement_cap` | `VirtualProtect`, `memcpy` of instruction bytes, permission restore | H + M | **Exclude from public baseline** without explicit authorization |
| `src/attila/battle_hooks.cpp` / `EnableSmeHealthBars` | Installs/removes card/battle hook through native API | H + U | Separate explicit opt-in, review hook ownership and publisher terms |
| `src/attila/campaign_ui.cpp` | Contains native hooks for settlement/UI behavior | H + U | Exclude from standard Lua-only AEEF Core |
| `src/attila/campaign_model.cpp` | Contains native hook installation/removal | H | Inspect call graph, lifetime and exact-build compatibility |
| `src/main.cpp` / `luaopen_twdll` | Initializes Lua ABI, game API, hooks; cleanup on last Lua proxy GC | H | Do not describe library as “pure read-only” |
| `src/attila/security.cpp` / `is_valid_game_host` | Restricts module loading to expected host | ? | Host check is not permission/approval from publisher |

## Exported API inventory (source names; classification is preliminary)

The following exports were observed directly in repository sources. Methods are listed **individually** so the public API can be gated by a capability manifest. Classification of getters is by implementation intent/name unless otherwise noted; full per-function call-graph verification is still necessary.

| Module | R — read/inspect | M — write/game mutation | U / H / E / uncertain |
|---|---|---|---|
| `world` | `GetMemoryAddress`, `GetFactionCount`, `GetCaptureStatus`, `GetMaxUnitsInArmy`, `GetMaxUnitsInNavy`, `GetReinforcementCap`, `GetMaxTraits` | `SetMaxUnitsInArmy`, `SetMaxUnitsInNavy`, `SetReinforcementCap`, `SetMaxTraits` | E: `SaveGame`, `LoadGame`, `ExitToMainMenu`, `ExitGame`; H: world constructor installation and reinforcement patch |
| `faction` | `GetMemoryAddress`, `GetTreasury`, `GetTechnologyStatus`, `GetPoliticalPartyList`, `GetPoliticalParty`, `GetPrimaryParty`, `HasPoliticalParties` | `SetTreasury`, `SetFactionLeader`, `SetCapital`, `InstantlyResearchTechnology`, `SetTechnologyStatus`, `CreateAgent` | Native object pointers/engine entry points still require inspection |
| `character` | `GetMemoryAddress`, `GetActionPoints`, `GetInfluence`, `GetPoliticalParty`, `GetArtSet`, `GetTraitList`, `GetLoyalty`, `GetLoyaltyModifier`, `GetLoyaltyFactorList`, `GetFullName`, `GetForename`, `GetForenameKey`, `GetFamilyName`, `GetFamilyNameKey`, `GetClanName`, `GetClanNameKey`, `GetOtherName`, `GetOtherNameKey`, `IsImmortal`, `GetResurrectionTurns` | `SetActionPoints`, `SetInfluence`, `SetDefaultBodyGuard`, `SetPoliticalParty`, `SetArtSet`, `AddTrait`, `RemoveTrait`, `SetLoyaltyModifier`, `TransferToFaction`, `SetForename`, `SetForenameKey`, `SetFamilyName`, `SetFamilyNameKey`, `SetClanName`, `SetClanNameKey`, `SetOtherName`, `SetOtherNameKey`, `SetImmortal`, `SetResurrectionTurns` | Mutation may affect saves/MP, require explicit deterministic proof |
| `unit` | `GetMemoryAddress`, `GetNumMen`, `GetMaxNumMen`, `GetActionPoints` | `SetNumMen`, `SetMaxNumMen`, `SetActionPoints`, `ConvertUnit`, `Disband` | Campaign/battle phase correctness and peer parity not proven |
| `region` | `GetMemoryAddress`, `GetPopulationSurplus`, `GetGrowthPoints`, `GetReligionList`, `GetReligionProportion` | `SetPopulationSurplus`, `SetGrowthPoints` | No publisher approval inferred |
| `military_force` | `GetMemoryAddress`, `GetRecruitmentQueueSize`, `GetIntegrity`, `HasIntegrity` | `DisbandUnits`, `SetIntegrity`, `AppointCharacter` | `AppointCharacter` and `DisbandUnits` require gameplay/persistence proof |
| `battle_unit` | `GetMemoryAddress`, `GetChargeBonus`, `GetMeleeAttack`, `GetBaseMorale`, `GetMeleeDefence` | None seen in this export table | R intent only; obtaining pointers through native engine remains elevated |
| `model` | — | `DisbandUnits` | Phase/ownership semantics to audit |
| `campaign_ui` | `GetMemoryAddress`, `GetMaxSlotsMajor`, `GetMaxSlotsMinor`, `GetEncyclopediaUrl` | — | U: `ClearMaxSlots`, `SetMaxSlotsMajor`, `SetMaxSlotsMinor`, `RefreshSettlements`, `SetEncyclopediaUrl`; native hooks present |
| `battle` | `GetBattleInfo` | — | H + U: `EnableSmeHealthBars` |
| `core` | `GameBuild`, `GetBuildSha` | — | Diagnostic output: `Log` |
| `tweakers` | `GetName`, `GetCategory`, `GetTitle`, `GetDescription`, `GetFile`, `GetLine`, `GetInt`, `GetFloat`, `GetBool`, `GetRawValue`, `GetValue`, `Find`, `GetList`, `Dump` | `SetInt`, `SetFloat`, `SetBool`, `SetRawValue`, `SetValue` | Setter registrations occur on multiple native objects; verify all mutation pathways |

**Coverage limitation:** This is a detailed audit of the listed exported modules, not an exhaustive inventory of every method registered dynamically by `register_*_methods`, every `cai` interface, or every helper in the native tree. Do **not** interpret absence from this table as a safety approval.

## Licensing and distribution

`native/twdll/UPSTREAM.md` identifies original `bukowa/twdll`, imported fork `karnalooch/twdll`, and GPL-3.0, plus vendored MinHook with separate license. Verify compliance with **GPLv3 §5–§6**, exact-source availability, corresponding build scripts, modification and copyright notices, and every bundled third-party dependency. This does not authorize access to SEGA proprietary game code.

For a public AEEF release:
1. Keep an independent Assembly Kit / ordinary Lua / DB-only core that does not require twdll or memory hooks.
2. Separate optional native GPL component and its source/release provenance; require an explicit publisher compliance review before public distribution.
3. Do not distribute Attila executables, proprietary game assets, or modified binaries.
4. Exclude memory/instruction patching, CRC/DRM bypass or stealth features from the approved release lane.
5. If permission is ambiguous, request written SEGA/CA clarification; no positive answer should be inferred from historical non-enforcement.
6. Expose no raw pointers, addresses, timing or local-state observations as deterministic multiplayer authority.

## Next audit work and proof gates

- [ ] Enumerate all `register_*_methods`, exported `cai` entry points and indirect mutation helpers using AST/source-based tool; resolve name collisions and wrapper methods.
- [ ] Generate machine-readable `capabilities.json` tagged R/M/U/H/E and block **unreviewed** exports from an opt-in native interface. Do not classify unknown as safe.
- [ ] Build call graph for all setters and all uses of `VirtualProtect`, `MH_*`, `WriteProcessMemory`, instruction writes and API hooks.
- [ ] Verify GPL correspondence for existing exact-SHA GitHub Actions archives and RPFM/MinHook license notices.
- [ ] Capture official Attila-specific Modding Terms version/date and, if necessary, seek publisher guidance for hooking and memory edits.
- [ ] Validate that Lua-only AEEF Core works without the native binary.
- [ ] CI static checks plus risk review; real Attila runtime and legal authorization are distinct evidence gates.
- [ ] Do not make public “publisher approved” / “safe from bans” claims without a publisher source.

## Source provenance

- Repository files inspected on PR #45 branch on 2026-10-08: `native/twdll/src/attila/{world,faction,character,unit,region,military_force,battle_unit,model,campaign_ui,campaign_model,battle_hooks,tweakers}.cpp`, `native/twdll/src/main.cpp`, `native/twdll/src/common/lua_core.cpp`, `native/twdll/src/attila/security.cpp`, `native/twdll/UPSTREAM.md`.
- SEGA terms: https://games.sega.com/eula/ ; https://privacy.sega.com/pl/sega-umowa-licencyjna-uzytkownika-koncowego-sega-eula
- GNU GPLv3: https://www.gnu.org/licenses/gpl-3.0.html ; FSF FAQ: https://www.gnu.org/licenses/gpl-faq.html

*This file records source observations and risk recommendations, not a legal opinion or proof that any particular function is used by the Workshop SP probe.*

## MK1212 interface changes vs native UI intervention — SEGA terms review

**Decision record (2026-10-08).** The baseline MK1212 mod contains changes to user interface presentation and interactions. It is essential not to conflate **Lua/DB/UI content modding** with **native hooks or writes to the game's process memory**. Neither the quantity of UI changes nor their visual prominence alone determines permission or legality; the *mechanism*, third-party asset ownership, applicable Attila modding permissions and distribution conditions matter.

### EULA and modding terms: points to check in the controlling version

The earlier legal research examined the SEGA Europe EULA and published modding terms (reported effective date: 2025-12-01) together with the Polish EULA. The following are **summaries of that review**, not legal quotations or independent verification of section numbering in this commit:

| Provision referenced in prior review | Working interpretation for this project | Verification needed before release |
| --- | --- | --- |
| SEGA EULA §7(e) | Limits modifying/decompiling/reverse-engineering the product, subject to applicable-law exceptions | Confirm the controlling agreement, exact language and applicability to Attila |
| SEGA Modding Terms §1 | Distinguishes modder-created material and publisher intellectual property | Verify rights to every distributed script, image, icon, text and asset |
| SEGA Modding Terms §2 | Provides a modding pathway using publisher-provided tools | Check Attila's official Assembly Kit and Workshop scope, not merely a general SEGA permission |
| SEGA Modding Terms §3 | Includes content and third-party-rights requirements | Review licensing, attribution and content provenance |
| SEGA Modding Terms §6 | Reserves publisher/platform rights to withdraw distribution or permission | Record takedown and uninstall/rollback procedure |

Interpret the EULA's general modification restrictions **alongside the express, applicable modding permissions**, rather than presenting normal Assembly Kit work as inherently prohibited. The existence of official Attila modding tools does **not** constitute general publisher approval for native in-process code hooks.

Primary terms for further verification:
- https://games.sega.com/eula/
- https://privacy.sega.com/en/sega-europe-end-user-license-agreement
- https://privacy.sega.com/pl/sega-umowa-licencyjna-uzytkownika-koncowego-sega-eula
- Official Total War: ATTILA Assembly Kit documentation: https://wiki.totalwar.com/w/Assembly_Kit_(TWA).html

### Two different technical pathways

| Mechanism | Concrete example | Engineering recommendation |
| --- | --- | --- |
| Supported Lua, database and UI content | New panels, buttons, text, icon/layout and faction display via available Attila modding interfaces | **Prefer in AEEF Core**, audit asset rights and tested compatibility |
| Native UI observation | `twdll.campaign_ui.GetMemoryAddress`, `GetMaxSlotsMajor`, `GetEncyclopediaUrl` | Optional diagnostic; even a getter may depend on native hooks, no automatic publisher approval |
| Native UI mutation | `SetMaxSlotsMajor`, `SetMaxSlotsMinor`, `ClearMaxSlots` | Separate #60 permission/compliance gate before public packaging |
| Native engine refresh and pointer overwrite | `RefreshSettlements`, `SetEncyclopediaUrl` | Higher risk; source includes internal engine calls and memory protection/write operations |
| Native hook lifecycle | `MH_CreateHook`, `MH_EnableHook`, `MH_DisableHook`, `MH_RemoveHook` | Native research only until Attila-specific terms are clarified |

**Repository evidence:** `native/twdll/src/attila/campaign_ui.cpp` exports the named functions; its hook teardown invokes `MH_DisableHook`/`MH_RemoveHook`, and its encyclopedia URL path uses `VirtualProtect` plus a process-memory pointer assignment. **This proves what the twdll module is capable of, not that MK1212's regular Workshop UI invokes those functions.** An explicit call-graph audit would be required to establish usage.

### Polish law: distinguish study from arbitrary engine changes

Prior research referenced Article 75(2)(2) of the Polish Copyright Act concerning observation, study and testing of software functioning by a lawful user, and Article 75(2)(3) concerning specific interoperability-related activities. These are conditional statutory provisions, **not a blanket authorization to patch executable instructions**, and applicability to particular Attila/twdll activities requires legal analysis. Use the official legislation portal to verify wording and current version: https://eli.gov.pl/ .

### Release choices and outstanding evidence

1. Keep standard MK1212 Lua/DB/UI fixes and AEEF Core on the officially supported modding lane, subject to game-specific terms and asset rights.
2. Preserve a completely **DLL-free, functional public Core baseline**; Native cannot be a mandatory dependency.
3. Keep WORLD hooks, native UI alterations and executable-memory modifications in a separate review track; do not imply published CI artifacts have SEGA authorization.
4. No publisher approval for public distribution of the current native hooks has been established. **Absence of an explicit authorization is uncertainty, not proof of criminal illegality**; contract breach, statutory exceptions and bans are separate questions.
5. Review the actual Workshop UI scripts and assets, their source/licensing, and concrete invocation paths before declaring individual features compliant.
6. Obtain written guidance from SEGA/Creative Assembly where native permission remains ambiguous. Do not introduce DRM/CRC bypass, executable redistribution, stealth or anti-detection tactics.
7. Document GPL-3.0 obligations for twdll independently from publisher authorization and distinguish **SOURCE-OBSERVED** from **RUNTIME-PROVEN**.

**Decision:** Routine UI changes made through Attila-supported Lua/DB tooling are not categorically disallowed just because they modify game UI; native interception and memory writes receive a separate elevated review. This is a risk-management recommendation, **not legal advice nor a guarantee against takedown or Steam sanctions**.
