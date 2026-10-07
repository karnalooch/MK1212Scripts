# twdll runtime/code audit

Status: **REPO-OBSERVED + repository/native CI PASS**; Attila runtime proof pending  
Audit issue: #40  
Audit PR: #41  
Audit date: 2026-10-07  
Audited baseline: `MK1212Scripts@5b7627f7702966ce904d6c094389191c7c318ddc`  
Scope: active Attila path in `native/twdll/`; Rome 2 remains frozen

## Executive result

The previous monorepo audit proved that twdll had been imported faithfully. This audit answers a different question: **is the active twdll implementation itself safe enough to become MK1212's native observability backend?**

The answer is:

> **Repository-level hardening is substantially improved, but current-build Attila runtime compatibility is still not proven.**

The audit found several real implementation defects rather than only documentation gaps:

- signature scanning had an unsigned-underflow/out-of-bounds case and skipped the final valid match position;
- an empty signature could resolve falsely to the image base;
- `DllMain` performed logging/file I/O while the Windows loader lock was held;
- Lua ABI resolution could leave null function pointers while the DLL continued into module registration;
- multiple Lua states shared one process-global initialized flag, so teardown of one state could dismantle hooks still needed by another;
- several MinHook install paths could leave a created/enabled subset behind after a later failure;
- SME health-bar setup could report success while required hook signatures were absent;
- `SetFactionLeader(..., true)` read a Lua boolean through the integer conversion path;
- negative region values wrapped into large unsigned integers;
- `LoadGame` could report success when no native load function was resolved;
- campaign-variable raw-value synchronization converted raw bits numerically instead of preserving the bit pattern;
- campaign-variable rollback conflated two engine copies into one snapshot;
- unsupported `TWEAKER_SCRIPT_INTERFACE:SetValue` inputs could report success without a valid mutation;
- the process-host check matched `attila.exe` as a substring instead of requiring the actual executable basename;
- `twdll.log` had no size or per-message budget.

All of those findings are addressed on the audit branch. The remaining items below require exact-build runtime evidence or targeted reverse engineering and are deliberately **not guessed into a fix**.

## Audit boundary

### Included

- `src/main.cpp` loader/module lifecycle;
- `src/common/` signature scanner, Lua ABI bridge, game API bridge and native logging;
- active `src/attila/` hook ownership and Lua-exposed runtime mutations;
- MinHook integration/lifecycle;
- Attila x86 ABI assumptions and compile-time layout assertions;
- Lua userdata wrapping/unwrapping and stack-facing API patterns;
- save/load-facing runtime functions;
- multiplayer/desync observability boundaries;
- CMake/native CI coverage.

### Excluded

- frozen `src/rome2/`;
- rewriting vendored MinHook internals;
- redistributing or patching proprietary Attila binaries;
- inventing new offsets/signatures without exact-build evidence;
- claiming multiplayer safety from repository-only tests.

Vendored MinHook remains pinned to `TsudaKageyu/minhook@d94c64d32ea37bc4f5ee47d580709f70c6fb6080`.

## Findings and disposition

| ID | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| TWD-A01 | HIGH | `Scanner::find_signature` underflowed when pattern length exceeded image size, skipped the last valid start offset and accepted empty patterns as a match at image base. | **FIXED**; bounds/empty/malformed handling plus native regression tests. |
| TWD-A02 | HIGH | `DllMain` called `Log()`, which takes a C++ mutex and opens/writes a file under the Windows loader lock. | **FIXED**; `DllMain` now only disables thread notifications on attach. |
| TWD-A03 | HIGH | Lua ABI initialization was best-effort even though module registration dereferences those pointers immediately. Missing signatures could become null function-pointer calls. | **FIXED**; all 23 required Attila Lua signatures must resolve or `luaopen_twdll` aborts fail-closed. |
| TWD-A04 | HIGH | Hook creation/enabling was not transactional. Several paths could leave a created hook, or one half of a multi-hook feature, after a later error. | **FIXED**; local rollback added for WORLD, CAMPAIGN_UI, settlement slots, CAMPAIGN_MODEL, BATTLE and CAI occupation hooks. |
| TWD-A05 | HIGH | SME health-bar setup could return success if one/both required addresses were unavailable and could leave only one of the two hooks active. | **FIXED**; both signatures are required and failures roll back the pair. |
| TWD-A06 | MEDIUM | Process-global hook teardown was tied to a single Boolean rather than Lua-state ownership. One state GC could remove hooks used by another state. | **FIXED**; module roots are counted and hooks uninstall only after the last registered Lua state is collected. |
| TWD-A07 | MEDIUM | Host validation accepted any executable path containing `attila.exe`. | **FIXED**; the lowercase executable basename must equal `attila.exe`, and `empire.retail.dll` must be loaded. |
| TWD-A08 | MEDIUM | `SetFactionLeader(..., true)` used `lua_tointeger` semantics for a boolean. | **FIXED**; boolean path uses `l_tobool`. |
| TWD-A09 | MEDIUM | Negative population-surplus/growth values were cast directly to unsigned integers. | **FIXED**; negative Lua values clamp to 0; regression cases added to the in-game Lua test source. |
| TWD-A10 | MEDIUM | `world.LoadGame` returned true even if `g_load_game` was unresolved. | **FIXED**; unresolved native dispatch now returns false. |
| TWD-A11 | MEDIUM | Game API re-resolution could retain stale target values and had no aggregate degraded-mode summary. | **FIXED**; all 33 targets are cleared before scan and the resolved/total result is logged. Missing game signatures disable affected features rather than the whole module. |
| TWD-A12 | MEDIUM | Campaign-variable `SetRawValue` numerically converted a raw `uint32_t` to float, changing its bit meaning. | **FIXED**; raw bits are copied into the float representation. |
| TWD-A13 | MEDIUM | Campaign-model and database campaign-variable copies shared one rollback value even though they are separate storage locations. | **FIXED**; each location snapshots/restores its own original runtime value. |
| TWD-A14 | MEDIUM | Unsupported `TWEAKER_SCRIPT_INTERFACE:SetValue` types returned success. | **FIXED**; only boolean/number inputs succeed. |
| TWD-A15 | MEDIUM | Native diagnostics were unbounded; high-rate CAI/runtime logging could grow `twdll.log` indefinitely. | **FIXED**; 8 MiB file ceiling, 4096-byte message ceiling and 64 Lua arguments per call; budget exhaustion is fail-soft and never truncates old evidence. |
| TWD-A16 | MEDIUM | x86 `FindPushRef` used `uintptr_t` width and unaligned pointer dereference for a 4-byte x86 immediate. | **FIXED**; reads a `uint32_t` via `memcpy`. |
| TWD-A17 | MEDIUM | `FindString` could read one byte beyond the supplied range at the final loop position. | **FIXED**; the scan now reserves a byte for the required NUL terminator. |
| TWD-A18 | MEDIUM | `FindPrologue` could wrap an unsigned address when asked to scan to address zero. | **FIXED**; invalid origins fail closed and the loop has an explicit terminal condition. |
| TWD-A19 | MEDIUM | The logger enforced byte ceilings while the file was opened in Windows text mode, so `\n` expanded to `\r\n` and could exceed the advertised 4096-byte line / 8 MiB file limits by one byte. | **FIXED** during stress testing in #42/#43; `twdll.log` is opened in binary append mode and the byte-budget regression test proves the exact ceiling. |

## Remaining risks — not papered over

### R1 — runtime build compatibility is still unproven

**State: BLOCKED on an exact Attila runtime pass.**

The code contains extensive `TW_ASSERT_OFFSET` checks. Those assertions prove that the C++ declarations match the offsets the source expects; they do **not** prove that the current installed Attila executable uses those offsets.

Required evidence remains:

- exact `Attila.exe` / `empire.retail.dll` build identity;
- successful module load;
- 23/23 Lua signatures in the actual process;
- observed game-signature resolution;
- singleton construction/destruction;
- save/load reinitialization;
- clean exit/unload.

### R2 — userdata type confusion

**State: REPO-OBSERVED / runtime hardening pending.**

`tw_unwrap<T>` verifies null pointers but does not validate that the Lua userdata in a slot actually belongs to the expected metatable/type. Passing the wrong native userdata to a method can therefore reinterpret the wrapper as another engine type.

A safe generic fix requires a proven Lua-side type-check primitive/metatable contract. This audit does not invent one.

### R3 — full-image signature scans can still cross unreadable pages

**State: REPO-OBSERVED.**

The scanner now respects the supplied numeric range, but it still walks `MODULEINFO::SizeOfImage` as a flat byte range. A mapped image can contain inaccessible pages/gaps; a normal C++ exception handler does not convert a Windows access violation into a recoverable scan miss.

A future hardening pass should either:

- scan validated PE sections only; or
- walk pages with `VirtualQuery` and skip non-readable regions.

That change should be proven against the exact Attila image rather than added speculatively.

### R4 — deliberate raw-memory mutation surface

**State: REPO-OBSERVED / high-risk capability.**

Several twdll APIs intentionally mutate engine structures. The audit identified paths that deserve targeted runtime proof before MK1212 relies on them, notably:

- manual trait/vector mutation;
- bodyguard/general appointment internals;
- campaign tweaker mutation;
- executable instruction patching for reinforcement cap;
- direct singleton/structure field writes.

These capabilities are not evidence that they are multiplayer-safe. For MK1212 they remain outside the normal gameplay authority path.

### R5 — hardcoded/raw struct navigation still exists in active Attila code

**State: REPO-OBSERVED.**

The project convention now requires engine data paths to be represented in `tw_types.h` and asserted. Some older imported functions still contain direct offset/navigation logic. The audit deliberately does not replace those offsets from guesswork. Each such path needs targeted exact-build verification before refactoring.

### R6 — stale native object lifetime during teardown

**State: HYPOTHESIS requiring runtime evidence.**

Tweaker snapshots store engine pointers for rollback. The new rollback semantics preserve the correct original values, but the lifetime of every pointed-to tweaker across campaign unload/reload still needs an in-game teardown test. A repository build cannot prove pointer lifetime.

## Multiplayer / simultaneous-turn conclusions

The audit strengthens twdll as an **observability backend**, not as a simultaneous-turn implementation.

### Safe architecture after this audit

- DLL load/signature failure disables native diagnostics rather than inventing state;
- raw memory addresses remain process-local diagnostics;
- game-signature gaps are capability degradation, not shared-gameplay fallback;
- logs are bounded and fail-soft;
- build identity remains the MK1212Scripts SHA;
- hook partial failure no longer leaves a knowingly half-installed instrumentation state.

### Still forbidden as shared MP authority

Do not drive shared multiplayer mutations from:

- raw pointers or module/hook addresses;
- local UI state;
- local wall-clock/thread state;
- native values that have not been compared on both peers;
- a feature that exists on only one peer because a signature resolved locally.

### Best next use for simultaneous-turn research

Use twdll to capture **passive, semantic checkpoints** around:

1. turn start;
2. faction hand-off;
3. pre/post AI cycle;
4. save/load;
5. battle-to-campaign return;
6. known invasion/diplomacy/Papal transitions.

The first goal is to locate the earliest HOST/CLIENT semantic divergence. Do not move from observation to native-driven gameplay until exact-build two-peer determinism has been demonstrated.

## Test coverage added by the audit

Repository-native scanner tests cover:

- first-position match;
- wildcard match;
- final valid start offset;
- pattern larger than search range;
- empty and null patterns;
- malformed hex tokens;
- NUL-terminated string scan boundaries;
- x86 PUSH immediate resolution;
- prologue scan terminal behaviour.

The root Windows CI lane now explicitly configures `BUILD_TESTING=ON`, builds the x86 DLL and scanner-test target, runs `ctest`, then verifies the PE32/x86 and `luaopen_twdll` artifact contract.

The in-game Lua test source also contains regression checks for negative region input clamping. Those real-game tests are **not** GitHub Actions proof and must still be run in Attila.

## Repository/native CI proof

PR #41 first completed the full caller-local proof on exact functional head
`14504540262b24fb9019c63e5bec1d715010b946` in **Gumball CI run #42 / run ID 37627081586**.

That exact-head run proved:

- exact checked-out revision assertion: **PASS**;
- repository static contract: **PASS**;
- deterministic MP dual-peer repository simulation: **PASS**;
- governance: **PASS**;
- repository policy / Git LFS policy: **PASS**;
- Trivy filesystem scan: **PASS**;
- Attila Visual Studio Win32 configure/build/link: **PASS**;
- `twdll_signature_scanner_tests` build: **PASS**;
- native scanner CTest execution: **PASS**;
- PE machine contract `IMAGE_FILE_MACHINE_I386 (0x014c)`: **PASS**;
- `luaopen_twdll` export-marker contract: **PASS**;
- caller-local Aggregate CI gate: **PASS**.

The follow-up commit that records this evidence is documentation-only and must itself retain a green exact-head gate before merge.

## Stress follow-up — issue #42 / PR #43

The post-audit stress pass deliberately tightened the proof boundary beyond the original #41 native build check.

Exact stress head `dcc1284016b7f07b27575018eb1d8124aac3af4f` completed **Gumball CI run #47 / run ID 37630813021** successfully.

The stress lane now proves on Windows x86:

- active Attila C++ path compiles in **Release and Debug** with MSVC `/W4 /WX`;
- signature scanner passes its boundary suite plus **5,000 deterministic randomized exact/wildcard cases per configuration**;
- logger passes formatting, truncation-marker, **8-thread / 2,000-line concurrent write**, exact **8 MiB** cap and no-growth-at-cap tests;
- host guard accepts only an exact case-insensitive `attila.exe` basename and rejects the CI test process;
- all three native CTest executables pass in **Release and Debug**;
- PE32/x86 and `luaopen_twdll` artifact contracts remain green;
- Linux source-contract tests continuously guard the #40/#41 fail-closed and MinHook rollback invariants;
- repository policy, governance, Trivy, deterministic MP repository simulation and Aggregate CI all remain green.

The stress suite itself found **TWD-A19**, proving that the additional test layer is not ceremonial.

## Proof labels

At this stage:

- source/code review: **REPO-OBSERVED**;
- exact functional-head native x86 compiler/link proof: **PASS**;
- exact functional-head scanner regression suite: **PASS**;
- Release + Debug `/W4 /WX` native stress suite: **PASS**;
- logger concurrency/exact-budget stress: **PASS**;
- host guard native regression suite: **PASS**;
- source-contract guard for audit fixes: **PASS**;
- repository policy/governance/Trivy/Aggregate proof: **PASS**;
- current Attila load proof: **NOT RUN**;
- save/load runtime proof: **NOT RUN**;
- two-peer passive proof: **NOT RUN**;
- simultaneous-turn feasibility proof: **NOT RUN**.

Do not upgrade any runtime item to RUNTIME-PROVEN from CI alone.

## Decision

The audited branch is suitable for repository/build validation and then for the staged Attila runtime proof in `TWDLL_OBSERVABILITY_BACKEND.md`.

The current safety contract is:

> **Lua ABI: all required signatures or fail closed. Game API: per-capability degraded mode. Hooks: transactional rollback. Diagnostics: bounded and gameplay-neutral. Runtime-derived gameplay authority: forbidden until exact-build dual-peer proof.**
