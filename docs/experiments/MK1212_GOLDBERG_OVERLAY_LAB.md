# MK1212 — Experimental Goldberg Overlay (operator-only)

This experiment does **not** fix LAN lobbies by itself. It checks whether Attila can use Goldberg's experimental Steam overlay (Shift+Tab), see friends, and join via invite. The working LAN baseline remains unchanged until you explicitly enable the experiment.

## Prerequisites

- Previously prepared, owned HOST at `C:\MK1212\HOST` and CLIENT at `D:\MK1212\CLIENT`, each with `.mk1212-goldberg-copy.json`, `.mk1212-goldberg-settings.json`, `steam_settings`, and `steam_api.dll`.
- Sandboxie at `D:\Sandboxie-Plus`. Both games closed for Enable and Restore.
- Previously verified upstream archive `D:\MK1212\diagnostics\goldberg-original.zip` (or pass `-Archive`).
- **No Steam installation/game/mod re-copy**. Original `D:\SteamLibrary\steamapps\common\Total War Attila` is never written by this script.

Copy `goldberg_overlay_operator.ps1` and `RUN-GOLDBERG-OVERLAY.cmd` into the same folder (e.g. `D:\MK1212\Launcher`), then double click the CMD. Alternatively:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\goldberg_overlay_operator.ps1 -Mode Status
powershell -NoProfile -ExecutionPolicy Bypass -File .\goldberg_overlay_operator.ps1 -Mode Enable
powershell -NoProfile -ExecutionPolicy Bypass -File .\goldberg_overlay_operator.ps1 -Mode Launch
powershell -NoProfile -ExecutionPolicy Bypass -File .\goldberg_overlay_operator.ps1 -Mode Restore
```

**Use the sidecar's Launch while enabled**, **not** `RUN-INSTALLED-GOLDBERG.cmd`. That standard launcher verifies pinned normal DLL bytes and requires `disable_overlay.txt`. It is expected to reject the experimental configuration. After Restore it may be used again.

## What happens

- Checks ownership markers and lab identity, confirms the standard Goldberg DLL SHA-256 on both copies, confirms the required disable markers and no running Attila.
- Verifies pinned upstream ZIP SHA-256, extracts exactly one experimental x86 `steam_api.dll`, validates its PE machine type.
- Writes verified backups of BOTH DLLs and BOTH disable files; writes a journal at `D:\MK1212\diagnostics\overlay-lab\active.json` **before any mutation**.
- Atomically replaces DLLs in the **copies only**, removes exactly the two disable markers, and offers Sandboxie launch.
- Restore verifies backups and checks for unknown modification before restoring. The journal is removed **only on successful restoration**. Backups remain available.
- If interrupted or something fails, **close both games and run Restore**. Never delete `active.json` or backups to force another run.

## Manual test protocol

1. Enable and Launch.
2. HOST: open `Shift+Tab`; CLIENT: open `Shift+Tab`.
3. Confirm `MK1212_HOST` and `MK1212_CLIENT` show as contacts/friends, if the overlay exposes that UI.
4. HOST: create a LAN battle lobby, try inviting CLIENT from overlay; CLIENT: try joining.
5. Record: overlay shown YES/NO, friend shown YES/NO, invite sent/received YES/NO, lobby visible/join successful YES/NO.
6. Close both games and Restore. Only then return to the standard launch tool.

### Important limitations

- The pinned upstream Goldberg README says the overlay only exists in Windows experimental builds and warns that running two same-AppID games on one PC can cause network issues.
- Experimental overlay may hook rendering and networking and may crash or not display in Attila.
- Do not disable Windows Defender, Windows Firewall, or Sandboxie isolation to make the test pass.
- All results from this sidecar remain local operator observations; CI syntax/archive checks **are not** proof of real Attila multiplayer.
