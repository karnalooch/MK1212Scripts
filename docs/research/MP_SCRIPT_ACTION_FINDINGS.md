# Script actions: findings and proof boundaries

Reviewed 2026-10-11. Source baseline: PR #67 at
`49db5e129d87f2fbdc1b1e02333873caddb00437`; fixes and regression fixtures are part
of this change. A fixture result is evidence about the repository Lua executed
with substituted engine interfaces. It does not establish Attila multiplayer
transport, event order, or complete engine-state equality.

## 1. What the existing evidence actually establishes

The user's separate control observation is that multiplayer synchronization
worked with scripts disabled, while both original and optimized scripts
desynchronized. This prioritizes script actions, their event delivery, and saved
state. It does not identify one particular callback as the runtime cause.

The two inspected PR45 archives are **single-player runs with scripts active**:

| Archive | SHA-256 | Direct evidence |
| --- | --- | --- |
| `01-MK1212-PR45-SP-EVIDENCE-no-dll-20261008-090635-075.zip` | `cc288a2f8803bcd37c1b556e59c90667f7e9078580e0b40bbc58d1c7ab770bb9` | Two initializer/bootstrap segments; DLL unavailable; no shared-action trace. `result.json` reports `pass=false`, including a failed debug/fallback gate. |
| `02-MK1212-PR45-SP-EVIDENCE-native-20261008-084406-110.zip` | `ab105f50308e2eee2dc2b7437d2a71bcfce6bc6ec24c988c5b5be1e8c333e5dd` | Three initializer/bootstrap segments; native module ready; `world_not_captured` / `factions=nil`; `result.json` reports loader/probe success. |

In **both** archives, `moddata.used.json` sets `1-1212scripts.pack` active and
`1-1212allscriptsdisabled.pack` inactive. Every `session_begin` in
`MK1212_mp_debug.log` says `multiplayer=false`. Thus **no-DLL is not no-scripts**.
The native archive's `twdll.log` establishes resolved signatures and hook
installation, not a paired campaign execution. Neither archive contains paired
HOST/CLIENT faction turns, UI actions, timer effects, RNG draws, or save-state
comparisons. Multiple bootstrap segments alone do not label actual save/load or
battle transitions. The no-DLL trace also contains an embedded newline in its
failure reason; that diagnostic-format failure is not an MP outcome.

Both `manifest.json` files identify PR45 source
`bf8b4ec9357dca56f9e71c3a5407c9db574de0fd` and source pack SHA-256
`3ffe61270c953602783fcfde4723abf1d5bc698b958ef618f329d2e5b6369255`.
The actual subsequently supplied `1-1212scripts.pack` was read separately and
has that same hash: **343,198,063 bytes, 1,589 entries, 154 Lua files totaling
2,624,921 bytes**. All 154 Lua paths exist in the PR67 repository. This is an
inventory of the actual pack; the earlier ZIPs' `overlay.json` preservation
counts were harness metadata. See the independent
[pack inventory](../runtime/evidence/base-script-pack-20261011.json).
A release pack's own hash must come from its final build manifest, not from the
original pack hash or an uncommitted source tree.

## 2. Identified defects and bounded fixes

### Local difficulty affected shared calculations

**Documented source fact:** Creative Assembly's
[Attila Extra Scripting Guides](https://wiki.totalwar.com/w/Total_War:_ATTILA_KIT_-_Extra_Scripting_Guides),
`MODEL_SCRIPT_INTERFACE.difficulty_level()`, describes the returned value as the
local faction's difficulty. A calculation using it cannot assume equal input
on both peers. This is a source-backed synchronization risk, not evidence that
the user's particular peers had different settings.

`MK1212_Campaign_Difficulty()` supplies the content-defined normal baseline in
MP and retains selected difficulty in SP. Production War Weariness fixtures
give HOST easy and CLIENT legendary inputs and require identical shared
commands; separate SP tests preserve the different multipliers. Repeated
initialization also no longer compounds the multiplier or resets new-campaign
values. Sources: [common helpers](../../campaigns/main_attila/common/mk1212_common.lua),
[War Weariness](../../campaigns/main_attila/mechanics/mechanics_war_weariness.lua),
[script-action fixtures](../../scripts/ci/fixtures/mp_script_actions.lua).

### Repeated faction-turn callbacks repeated additive work

War Weariness now records the completed faction/round before the first additive
change. Its owned, bounded version-1 ledger survives save/load. Tests exercise
duplicate and reentrant callbacks, asymmetric duplicate delivery to HOST,
reload within the same round, and next-round progress. A claim made before a
partially failed engine command prevents blind replay; it does not repair that
command. Invalid/unknown ledger metadata is retained and stops passive turn
processing instead of guessing completion.

Old saves have no completion ledger. Loading them does not execute a turn, but
the script cannot reconstruct whether a later repeated callback refers to work
performed by an older version. Battle and peace callbacks remain separate:
validating both battle results before either participant changes is not a
general exactly-once battle protocol. See
[phase-state contract](MP_DUAL_PEER_SIMULATION.md#war-weariness-phase-state).

### A local Pope election panel consumed campaign RNG

`RefreshPopeElectionPanel()` drew placeholder vote counts from
`MK1212_Random_Int()` during a local vote-button refresh. A production-Lua test
that delivered those clicks only to HOST failed before the fix. The panel now
uses fixed presentation placeholders, reuses existing image components, and
does not change actual election votes. Repeated local refreshes consume zero
campaign draws; the next shared draw remains equal in the two environments.

**Reachability qualification:** the College of Cardinals require and
initialization are commented out in the default Pope module. This is a latent
unfinished-feature/saved-UI-state defect, not an established cause of ordinary
default-campaign desynchronization. Sources:
[Pope module](../../campaigns/main_attila/mechanics/pope/mechanics_pope.lua),
[UI](../../campaigns/main_attila/mechanics/pope/mechanics_pope_ui.lua),
[HOST-only UI fixture](../../scripts/ci/fixtures/mp_ui_rng.lua).

### Mecca's destruction state and listener ownership were inconsistent

The raze listener reused Population's listener identifier. The destruction path
did not reliably retain its actor as a saved faction key, while refresh passed
the stored value to a function expecting an engine interface. The revised
listener has its own ID, resolves the saved key through the current world,
claims destruction before effects, and suppresses a duplicate destruction
popup. Recapture resets that claim so a distinct later destruction can execute.
Tests cover coexistence with Population's listener, save/reload, repeated raze,
recapture, and missing entities. These tests do not establish the engine's
actual listener replacement or occupation-event order.

An adjacent preexisting behavior was independently reproduced: for a continuing
non-Muslim occupation, the human-turn refresh removes all Mecca effects and the
already-occupied branch restores only the occupier's outcry. Muslim factions'
dejection is then absent. This is distinct from destruction-state persistence
and must not be described as fixed merely because the raze regression passes.
Source: [Mecca lifecycle](../../campaigns/main_attila/mechanics/islam/mechanics_islam_mecca.lua).

### Saved strings, numeric conversion, and diagnostics needed stronger contracts

Schema 3 preserves literal empty strings, percent signs, delimiters, control
bytes, and Unicode city names through framed, escaped scalar values. Schemas
0/1/2 remain literal: an old `%2C` or `MK1212_SAVE_V3|City` is not silently
reinterpreted. Duplicate/colliding keys, malformed rows, unknown schemas,
non-finite scalars, and oversized payloads are rejected explicitly. Limits are
checked during encoding; the legacy 20,000-row map capacity was not reduced to
10,000 by counting keys and values separately.

Independent regressions cover 10,001 legacy rows, save/load/save byte equality,
literal migration, punctuation-rich city names, and thrown checksum/logger
errors. Legacy city values already corrupted by an unescaped comma cannot be
reconstructed safely; rejection is not recovery of their intended text.

The real vendored Lua 5.1 runtime reproduced a numeric-locale defect:
`tonumber("1.5")` returns `nil` under a Polish comma locale, even though new save
bytes contain `1.5`. The narrow fix adapts the canonical decimal marker for the
native parser without changing the game's process locale or implementing new
floating-point arithmetic. A committed regression generates a private locale
with `localedef` when available and checks exact numeric values and equal saved
bytes under both locales. Linux CI sets `MK1212_REQUIRE_NUMERIC_LOCALE=1` and
fails if a comma locale cannot be installed or generated; unsupported local
environments without that requirement report an explicit test skip. The vendored
runtime defines `LUA_NUMBER` as `float`; these executions must not be presented
as proof of binary64-specific edge cases. String-key ordering is explicitly
byte-based because Lua 5.1 otherwise delegates string comparison to `strcoll`.

Save checksums are observational. A failing checksum or sink cannot prevent a
valid save. Framing detects a schema/payload mismatch; separate engine
`save_value` calls do not constitute a proven atomic transaction or recover a
torn outer game save. Sources: [codec](../../campaigns/main_attila/common/mkmp_persistence.lua),
[compatibility fixture](../../scripts/ci/fixtures/codec_review.lua),
[real-locale fixture](../../scripts/ci/fixtures/codec_numeric_locale.lua),
[vendored Lua configuration](../../native/twdll/docs/lua/lua_source/src/luaconf.h).

## 3. Diagnostic identity is necessary, but not execution evidence

The comparator previously accepted empty semantic traces, including the native
SP bootstrap against itself. It now reports `INSUFFICIENT EVIDENCE` for empty
logs and bootstrap-only logs. Malformed versions, duplicate fields, and invalid
escapes fail with an actionable parse error. Supported version-1 logs remain
readable.

`content_identity` records are compared, including source revision, profile,
multiplayer flag, and save schema. Identity missing on one side or differing
between peers is not discarded as local metadata. Matching identity plus
bootstrap still does not count as shared campaign execution. Historical logs
without identity on both sides can yield only the same explicitly limited
semantic-trace result. A successful comparison says
`scope=instrumented_semantic_trace runtime_mp_proof=not_established`.
See [comparator](../../scripts/ci/compare_mp_debug_logs.py) and
[evidence regressions](../../scripts/ci/test_mp_debug_evidence.py).

## 4. Evidence still required from two real computers

### Final source-advisory review

The exact committed diff guard reports three advisory patterns. Their review
does not disable the guard or convert missing runtime proof into a pass:

| Addition | Disposition |
| --- | --- |
| `pairs` in `MK1212_SaveDenseLength` | Counts and validates array keys only; iteration order does not select values, perform engine commands or control serialized order. The writer then traverses dense numeric indices. |
| Buffer `cm:add_time_trigger` | One bounded, named operation with captured targets and persistent phase ownership. Duplicate delivery is tested. Its local UI intent still lacks proven MP transport, so the feature remains experimental. |
| Pope UI `CreateComponent` | Reuses named icons and creates only missing presentation placeholders within the fixed row/count bounds. It consumes no campaign RNG; the unfinished College entrypoint remains inactive by default. |

The final local repair suite passed **88 MP/source/production-Lua tests** and
**19 pack tests**. The numeric locale test executed with
`MK1212_REQUIRE_NUMERIC_LOCALE=1`. Independent cleanup review additionally
injected an immortality-enable call that mutates and then throws; production
code now attempts restoration even for that first-command failure and preserves
later queued operations. Common loading also validates all its tables before
replacing that module's globals after a late malformed queue.

Both **Windows PowerShell 5.1** and **PowerShell 7** ran all **10** synthetic
installer cases in GitHub Actions run
[38105637218](https://github.com/karnalooch/MK1212Scripts/actions/runs/38105637218).
Those are filesystem tests, not game execution. That first run's governance
job rejected the old PR-body snapshot for lacking the exact manual-merge line;
the candidate still requires the complete Aggregate gate for its final SHA.

### Paired runtime matrix

Use two genuine Steam/Attila installations. Each run needs both peers' pack
hashes, build/profile identity, game build, ordered mod list, configuration,
starting-save identity, roles, precise actions, and paired logs. The intended
environment is two physical PCs, without Goldberg or Sandboxie.

| Scenario | Required paired observation |
| --- | --- |
| True no-scripts control | Confirm scripts are actually disabled on both PCs; distinguish this from removing a DLL. Record the same campaign progression used in the scripted test. |
| Scripted turn cycle | HOST, CLIENT, AI round, next player round: equal completed phases, War Weariness state, and shared mutations; log each peer's observed local difficulty separately. |
| Asymmetric local UI | Only HOST opens/clicks active UI, then only CLIENT; the next shared RNG call, arguments, result, and resulting state remain equal. Exercise the unfinished Pope panel only when that feature is explicitly enabled. |
| Pending action and timer | Schedule region A, select region B before completion, and schedule two distinct pending transfers: both peers retain the original actors/targets/order and execute each intended effect once. A captured local target alone does not prove synchronized intent delivery. |
| Duplicate events and reload | Record listener initialization, repeated callbacks, and save/load within an unfinished or completed phase. Verify no lost pending action and no replay of completed work. |
| Save-state comparison | Save punctuation/Unicode names and unequal same-length values; compare actual decoded state and recorded digests, then load and advance on both PCs. |
| Mecca lifecycle | Occupation, raze, duplicate delivery where observable, reload while razed, recapture, and another raze: equal actor keys, flags, effect bundles, and popup cardinality. |
| Battle return | Manual battle and autoresolve, campaign return, save/load, next shared turn: paired before/after traces and state; no assumption that equal bootstrap or runtime readiness proves these transitions. |

Local decisions, region trade, and buffer-state confirmation still require
evidence for the path from a local click to a shared accepted action. An engine
API name, a timer callback, matching mocked delivery, or a matching diagnostic
digest alone does not establish that transport contract. The first differing
shared-action record should determine the next investigation; a blanket claim
that multiplayer is repaired requires the missing runtime runs above.
