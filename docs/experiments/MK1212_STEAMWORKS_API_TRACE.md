# MK1212 — Steamworks API trace experiment

Status: SOURCE PATCH IMPLEMENTED; NATIVE DLL NOT BUILT; REAL ATTILA NOT TESTED.

## Purpose

HOST and CLIENT recognize each other in Goldberg overlay and UDP discovery, but neither campaign nor battle lobby appears. The pinned original Goldberg archive has an experimental overlay DLL but NO ready debug DLL (debug_experimental only contains a Readme). The API trace therefore requires rebuilding a separately instrumented emulator.

## Pinned source and events

Original upstream commit: 475342f0d8b2bd7eb0d93bd7cfdd61e3ae7cda24. Pinned original archive SHA256: 8465984b01b42a75f5faea8f2d884bbd6085a695c40c2b90eb0385f0a5081266.

The source patcher logs CreateLobby.call/return, LobbyCreated.callback, RequestLobbyList.call/return, LobbyMatchList.callback with match counts, new/old RequestLANServerList.call, ServerList.callback counts, JoinLobby.call, SetLobbyData.call, InviteUserToLobby.call, InviteUserToGame.call, ActivateGameOverlayInviteDialog.call.

Each trace log is named MK1212_STEAMWORKS_TRACE.log and is written in the process working directory (which Sandboxie may virtualize). Max size 2 MiB. No game metadata values, password contents or connect strings logged. An absent trace log is INCOMPLETE EVIDENCE, not proof the game never called an API.

## Prepare source on D: (no game write)

Have a checkout of the repo and pinned archive at D:\MK1212\diagnostics\goldberg-original.zip, then run:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnostics\Prepare-MK1212-SteamworksTrace.ps1

The script verifies ZIP and pinned source Git bundle, then creates a distinct source checkout at D:\MK1212\diagnostics\steamworks-trace-src\instrumented. Existing output stops the procedure. Original Steam installation, game copies and Workshop content are untouched.

## Optional x86 build (separate gate)

Pre-requisites: Visual Studio C++ x86 Build Tools; pre-installed x86-windows-static protobuf, default D:\vcpkg\installed\x86-windows-static. This step may need toolchain troubleshooting and has NOT BEEN RUN.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnostics\Build-MK1212-GoldbergTraceX86.ps1 -Protobuf D:\vcpkg\installed\x86-windows-static

The builder produces only D:\MK1212\diagnostics\steamworks-trace-x86\steam_api.dll and checks x86 PE + SHA256. It never installs the DLL into a game. Compile the non-overlay variant first to avoid unrelated overlay rendering regressions. Game deployment, rollback, session capture and operator acceptance remain separate tasks.

## Analyze collected independent traces

After a controlled deployment and before restoring, copy sandbox-visible logs as HOST-STEAMWORKS_TRACE.log and CLIENT-STEAMWORKS_TRACE.log under D:\MK1212\diagnostics, then run:

    python .\scripts\diagnostics\analyze_goldberg_steamworks_trace.py --host D:\MK1212\diagnostics\HOST-STEAMWORKS_TRACE.log --client D:\MK1212\diagnostics\CLIENT-STEAMWORKS_TRACE.log --output D:\MK1212\diagnostics\steamworks-report.json

The analyzer reports missing logs as INCOMPLETE, distinguishes missing callbacks from zero matches, and refuses oversized logs. Treat only real two-process capture with verified trace DLL as API evidence.

## Gates

- SOURCE_OK: exact Git commit + upstream blob hashes, original untouched.
- PATCH_OK: exact anchored functions/callbacks and negative mutation tests.
- BUILD_OK: verified MSVC Win32 binary and artifact SHA; currently NOT RUN.
- OPERATOR_OK: both sandboxed Attilas start with verified trace DLL; NOT RUN.
- EVIDENCE_OK: fresh HOST and CLIENT event traces aligned with campaign and battle search; NOT RUN.
- RESTORE_OK: original byte-exact DLLs and settings back; NOT RUN.
- MULTIPLAYER_OK: actual session join demonstrated; NOT PROVEN.

No auto-merge, no edits to Steam original, no 60 GB copies, no blanket firewall changes.