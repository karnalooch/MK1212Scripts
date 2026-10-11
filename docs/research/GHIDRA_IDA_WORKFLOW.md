# MK1212: Ghidra + optional IDA for native Attila research

Status: **repository tooling implemented; original Attila binary analysis NOT RUN**.
Issue: [#71](https://github.com/karnalooch/MK1212Scripts/issues/71).
Related: [N2/N4 native diplomacy experiment, draft PR #70](https://github.com/karnalooch/MK1212Scripts/pull/70).

## What this is

An offline, original-binary **static research** workflow. The operator needs the original Attila DLL or EXE from their own installation. An existing IDA/Ghidra project or dump is NOT needed. Ghidra finds bounded candidate symbols, strings and xrefs for diplomacy, treasury/payments, accepted proposals, commands/dispatch, network/serialization and start-of-turn/dilemma notifications. A finding is not a proven native function or network message. No runtime hooks, game modification, packet injection or synchronization work are performed.

## Portable, pinned installation — Windows

The toolchain lock is [scripts/re/toolchain.lock.json](../../scripts/re/toolchain.lock.json). It pins official Ghidra 12.0.1 (SHA256 85bd2990945f3a78df4d1e09f1bb1f40ab77be3bac62c6e7678900788c7f0f41; Apache-2.0) and portable Eclipse Temurin JDK 25.0.4.1+1 (SHA256 00c847d804f4a78e9f04f2683faf14fed898535b177b7fc704486cb0284e9283; GPLv2 with Classpath exception).

The installer downloads official archives over HTTPS, verifies SHA256 before extraction, validates ZIP paths and size and refuses to overwrite conflicting installations. No admin rights or global PATH modification. Downloads total over 650 MB, and extraction/projects require additional D: space. Ghidra/OS may still use small standard user-profile cache locations.

Run from a Git checkout of this project:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\re\Install-MK1212-RE.ps1" -Root "D:\MK1212\research"

Then analyze an original local game module:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\re\Invoke-MK1212-RE.ps1" -GameDirectory "D:\SteamLibrary\steamapps\common\Total War Attila" -Root "D:\MK1212\research"

The -GameDirectory shortcut specifically checks for empire.retail.dll. If absent, find the actual DLL/EXE and use -Binary "D:\path\to\original.dll". No binaries are included or downloaded by the project. The runner validates PE, x86/x64, SHA256 and the exact MK1212 source Git commit. -VerifyOnly checks the installed toolchain without downloads; -PlanOnly prints the proposed headless command after setup. If using source without .git, supply the real 40-character -RepositorySha.

The official analyzeHeadless runner uses two CPUs, a 600-second analysis limit and [Mk1212Leads.java](../../scripts/re/ghidra_scripts/Mk1212Leads.java). It retains a local Ghidra GUI-openable project under D:\MK1212\research\projects keyed by binary SHA. It does not edit the input game binary. Later runs process the same project without deleting earlier run reports.

## Outputs, verification and limits

Each run writes a new folder under D:\MK1212\research\reports\<binary-sha-prefix>\<run-id>:

- ghidra-leads.json: bounded and sorted string/function candidate references; max 300; explicit truncated flag.
- evidence.json: same leads plus tool version, source Git SHA, original PE name/SHA256/architecture.
- ghidra.log and ghidra-script.log: local execution diagnostics.
- Local Ghidra project files remain under D: and are **never shipping artifacts**.

Evidence status is always **STATIC_CANDIDATE_ONLY**. Binary-local addresses must not be transplanted across different game versions or architectures. There is no known function, packet ID, engine ABI or desync fix inferred by default.

Optional independent local report:

    python scripts/re/validate_leads.py --input "D:\MK1212\research\reports\...\ghidra-leads.json" --binary "D:\game\original.dll" --repo-sha <EXACT_40_HEX_SOURCE_SHA> --output "D:\MK1212\research\reports\...\review.md"

The validator rejects wrong binary SHA, non-PE input, bad schema/status, oversized candidates and evidence overwrite. Reports can include game-owned strings, so review before publishing. Do not commit proprietary binaries, database project files or disassembly.

## Optional IDA integration

IDA is **not required, installed or licensed by this project**. With an independently licensed IDA + IDAPython, open the same original binary and run [ida_export.py](../../scripts/re/ida_export.py) via IDA File > Script file. Select a new JSON path and validate it with the same offline validator. This is a competing static lead source, not an injection or patch tool.

## Why this matters to P2P synchronization

The priority is to follow one native player-to-player money transfer:

1. Accepted offer and its actual engine command, if any.
2. Ordering, transport and acknowledgment of that command (not merely the diplomatic popup).
3. Treasury debit and credit plus rejection/rollback/duplicate cases.
4. Notification/dilemma/turn callbacks and whether each occurs on both peers.
5. Source comparison to native/twdll faction.cpp, game_sigs.cpp and campaign_hooks.cpp.

The campaign variable diplomacy_smallest_payment is not itself a packet or command ID. Any new read-only twdll observer needs a **separate issue, exact-build analysis and HOST+CLIENT proof**. This tool does not upgrade N4 above ready_for_phase_proof.

Authority and guardrails: [twdll observability](TWDLL_OBSERVABILITY_BACKEND.md) and [MP runtime playbook](MP_RUNTIME_RESEARCH_PLAYBOOK.md). No game binaries or DRM/CRC bypass; no unsupported hook offset/ABI assumptions. Missing prerequisites = BLOCKED; truncated output = INCOMPLETE; no matching candidates = NOT FOUND IN STATIC SEARCH, not proof that a function does not exist.

Sources: [official Ghidra headless reference](https://github.com/NationalSecurityAgency/ghidra/blob/master/Ghidra/RuntimeScripts/support/analyzeHeadlessREADME.md), [official getting started](https://github.com/NationalSecurityAgency/ghidra/blob/master/GhidraDocs/GettingStarted.md), [Ghidra release](https://github.com/NationalSecurityAgency/ghidra/releases/tag/Ghidra_12.0.1_build), [Temurin release](https://github.com/adoptium/temurin25-binaries/releases/tag/jdk-25.0.4.1%2B1).
