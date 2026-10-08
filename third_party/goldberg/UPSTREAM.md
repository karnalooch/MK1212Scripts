# Goldberg Steam Emulator provenance

Status: **UPSTREAM-OBSERVED / EXPERIMENTAL**. ATTILA compatibility, lobby join,
campaign turns and save/reload are **NOT RUN** for this package. The emulator
changes the Steamworks implementation; its results do not establish that the
same scenario works with official Steam multiplayer.

## Locked upstream artifact

- Project: [Mr_Goldberg/goldberg_emulator](https://gitlab.com/Mr_Goldberg/goldberg_emulator).
- Source commit: `475342f0d8b2bd7eb0d93bd7cfdd61e3ae7cda24`.
- License: `LGPL-3.0-or-later`; upstream source headers and README state version 3
  or any later version. See `LICENSE.LGPL-3.0.txt` and `LICENSE.GPL-3.0.txt`.
- Official download index: <https://mr_goldberg.gitlab.io/goldberg_emulator/>.
- Fixed CI artifact: [job 4247811310](https://gitlab.com/Mr_Goldberg/goldberg_emulator/-/jobs/4247811310/artifacts/download).
- Retrieved and inspected on 2026-10-08. `lock.json` records the actual archive,
  selected DLL and included source bundle sizes and SHA-256 digests.

The download index identifies this commit and links this job. The downloaded
archive contains `job_id` with `4247811310`, and its source Git bundle contains
the same commit as `HEAD`, `refs/remotes/origin/master` and
`refs/pipelines/861033378`. The CI recipe at that commit creates the source
bundle with `git bundle create ... --all` and packages the Windows/Linux build
artifacts together. These observations associate the downloaded binary with the
upstream CI artifact. An independent rebuild or byte-for-byte reproducibility
check was **NOT RUN**. The original Windows CI uses a downloaded compiler/SDK
and prebuilt protobuf libraries; their exact source revisions are not
established by this lock.

## Package and runtime boundary

The final experiment ZIP includes the **whole unmodified upstream archive** at
`third_party/goldberg/goldberg-original-475342f0.zip`, including its source bundle
and upstream documentation. The archive and DLL are not committed to this
repository. Packaging must verify the archive digest before inclusion.

Runtime uses only the archive's root `steam_api.dll`. It is a PE32 x86 DLL
(`IMAGE_FILE_MACHINE_I386`, decimal `332` / hexadecimal `0x014c`), 1,488,896 bytes.
Static inspection found imports from `IPHLPAPI.DLL`, `WS2_32.dll`, `advapi32.dll`,
`SHELL32.dll` and `KERNEL32.dll`. Its exports include `SteamAPI_Init`,
`SteamAPI_InitSafe`, `SteamAPI_RestartAppIfNecessary`, `SteamAPI_RunCallbacks`,
`SteamInternal_CreateInterface`, `SteamUser`, `SteamMatchmaking` and
`SteamNetworking`. It has no Authenticode certificate. These are file inspection
results, not an ATTILA execution test.

The `experimental/`, `experimental_steamclient/`, `debug_experimental/` and
`lobby_connect/` contents are retained inside the original archive for exact
upstream preservation. The launcher must not deploy or execute them. The normal
x86 DLL does not require an additional Goldberg `steamclient.dll` or overlay DLL.
Game EXEs and assets come only from the user's existing installation and must
not enter the redistributable package. This experiment does not apply an EXE,
SteamStub, CRC or other additional protection patch.

## Corresponding source and license texts

`source_code/source_code.bundle` inside the unmodified archive is the upstream
source repository, including build scripts and bundled third-party source
notices. Its exact digest is in `lock.json`. After extracting that entry, it can
be inspected without using the emulator:

```sh
git clone source_code.bundle goldberg-source
git -C goldberg-source checkout --detach 475342f0d8b2bd7eb0d93bd7cfdd61e3ae7cda24
git -C goldberg-source rev-parse HEAD
```

`LICENSE.LGPL-3.0.txt` is an unchanged copy of `LICENSE` from that source commit.
`LICENSE.GPL-3.0.txt` contains the standard GNU GPL version 3 text incorporated
by LGPL version 3. The source bundle preserves third-party notices, including
the MIT notices in `json/json.hpp` and `json/fifo_map.hpp` and the public-domain
notice in `sha/sha1.hpp`. The unchanged root `Readme.txt` is retained inside
the downloaded archive. Its instructions describe more modes than this
experiment uses; the scoped runtime behavior above governs this package.

## Configuration reference for the pinned original build

This is the original **text-file** format. Newer forks use `configs.*.ini` and
must not be substituted under this lock.

All paths below are relative to an owned, separate copy containing the emulator
DLL. Write the small configuration values as ASCII or UTF-8 without a BOM.

| File | Meaning for this experiment |
| --- | --- |
| `local_save.txt` beside the DLL | A simple local directory name, at most 32 ASCII bytes, such as `goldberg_saves`; emulator state then lives relative to that DLL. |
| `steam_settings/steam_appid.txt` | `325610`; this file takes priority over working-directory, DLL-directory and environment app IDs. |
| `steam_settings/force_steamid.txt` | A distinct valid Steam64 individual ID per role; a local emulator identity, not a verified Steam account. |
| `steam_settings/force_account_name.txt` | A role name such as `MK1212_HOST` or `MK1212_CLIENT`. |
| `steam_settings/force_language.txt` | The same installed, supported game language on both roles. |
| `steam_settings/force_listen_port.txt` | A distinct intended TCP/UDP port per role, for example HOST `47584`, CLIENT `47585`. |
| `steam_settings/custom_broadcasts.txt` | The other role's loopback address and port, for example HOST targets `127.0.0.1:47585` and CLIENT targets `127.0.0.1:47584`. |
| `steam_settings/DLC.txt` | An existing empty file disables upstream's default unlock-all behavior. |
| `steam_settings/disable_overlay.txt` | An empty flag file disables the optional overlay. |
| `steam_settings/steam_interfaces.txt` | Interface versions extracted from the user's original Steam API DLL when available; the owned copy is the only output destination. |

Do not create `offline.txt`, `disable_networking.txt` or
`disable_lobby_creation.txt`: the first makes `BLoggedOn()` false, and the others
disable functionality needed for the experiment. No global emulator settings
need to be modified. ATTILA's own AppData profile remains a separate isolation
concern; `local_save.txt` controls only emulator storage.

The pinned `generate_interfaces_file.cpp` scans the original API DLL for known
interface-name prefixes followed by three digits, with a legacy controller
fallback. The runtime checks `steam_settings/steam_interfaces.txt` before the
file beside the DLL. Multiple different versions for one logical interface are
ambiguous: upstream silently uses the last matching line. A wrapper should
report that ambiguity rather than infer which version the game needs. The
upstream README specifically identifies API DLLs older than May 2016 as possibly
requiring this file.

## Network and compatibility limits

The source supports explicit `IP:port` custom targets (`dll/network.cpp`,
`Networking::resolve_ip`) and distinct listening ports. It can silently advance
to higher ports when a bind fails. Intended port availability and observed
runtime endpoints therefore matter; file configuration alone is not network
proof.

In this older implementation, `send_broadcasts()` returns before sending custom
targets when no broadcast-capable adapter is found. Keep an active ordinary LAN
adapter available even for the loopback experiment. Default LAN broadcasts are
still sent; specifying loopback custom targets does not restrict all game or
emulator traffic to loopback.

The upstream README warns that simultaneous copies of the same app ID on one
computer may have network problems. Sandboxie profile/process isolation and
distinct ports are an experiment, not an upstream guarantee. No broad IPC
openings, system firewall changes or security exclusions follow from that
warning.

The upstream README also states that additional game DRM can prevent a Steam
API replacement from working. Compatibility with the user's exact ATTILA build
must be observed. Failure at launch remains a reported limitation of this
experiment; it does not authorize additional binary patching.

Relevant pinned sources are `Readme_release.txt`, `generate_interfaces_file.cpp`,
`dll/settings_parser.cpp`, `dll/settings.cpp`, `dll/dll.cpp`, `dll/network.cpp`,
`dll/network.h`, `dll/steam_user.h` and `.gitlab-ci.yml` in the included source
bundle.
