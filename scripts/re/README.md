# MK1212 static Attila engine research

No existing dump or IDA installation is needed. Tools and local projects use D:\MK1212\research by default.

Install pinned Ghidra and Java:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\re\Install-MK1212-RE.ps1"

Analyze a locally owned original DLL or EXE:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\re\Invoke-MK1212-RE.ps1" -Binary "D:\YOUR_GAME_PATH\empire.retail.dll"

Read the local reports folder. Evidence status = STATIC_CANDIDATE_ONLY, not multiplayer proof. Optionally use ida_export.py inside a separately licensed IDA, then validate through validate_leads.py.

See [full research contract](../../docs/research/GHIDRA_IDA_WORKFLOW.md). Never commit game binaries, analysis DBs or raw decompilation.
