# MK1212 dual-client lab

Issue: [#62](https://github.com/karnalooch/MK1212Scripts/issues/62)

Status: **HYPOTHESIS / experimental external tooling**

Real Steam / ATTILA multiplayer proof: **NOT RUN** until operator evidence is supplied.

This package prepares two isolated Steam sessions on one Windows PC, using
standard Sandboxie boxes and the user's existing ATTILA installation. It checks
profile isolation, launches Steam, and collects bounded diagnostic evidence.
It does not install the game, install MK1212, or automate campaign actions.

## Start na Windows

1. Rozpakuj całą paczkę do **`D:\MK1212-DualClientTool`**. Katalog
   **`D:\MK1212-DualClientLab`** zostaw dla danych eksperymentu; skrypt utworzy go
   sam. Nie rozpakowuj narzędzia do folderu gry ani do katalogu danych laboratorium.
2. Uruchom **`RUN-DUAL-CLIENT-LAB.cmd`** i wybierz **1** (sprawdzenie stanowiska).
   Raport poda brakujące elementy albo wykryte ścieżki Steam, ATTILA i Sandboxie.
   Jeśli brakuje Sandboxie, jego oficjalna strona jest w sekcji Sources poniżej.
3. Wybierz **2** (konfiguracja). Narzędzie tworzy dwa własne kontenery:
   **`MK1212LabHost`** i **`MK1212LabClient`**. Przed kolejnym krokiem musi
   potwierdzić, że każdy ma oddzielny profil ATTILA.
4. Wybierz **3**, zaloguj pierwsze konto w otwartym Steam i uruchom ATTILA z jego
   biblioteki. Ustaw tryb okienkowy, niskie detale i małą rozdzielczość na początek.
5. Wybierz **4**, zaloguj drugie konto w drugim Steam i uruchom tam ATTILA.
   Przełączaj się między oknami przez Alt+Tab. Potrzebne są dwa konta oraz dwie
   dostępne kopie gry do jednoczesnej gry; samo drugie okno tego nie zapewnia.
6. Zacznij od **vanilla**. Na HOST utwórz lobby kampanii wieloosobowej; na CLIENT
   dołącz. Sprawdź wejście na mapę kampanii, jedną pełną turę oraz zapis i ponowne
   wczytanie. Zanotuj, na którym dokładnie kroku coś przestało działać.
7. Wybierz **5** podczas działania obu gier, aby zebrać procesy i logi. Powtórz po
   problemie albo po teście zapisu/wczytania. Każde zebranie dostaje nowy katalog;
   poprzednie dowody pozostają zachowane. Ścieżka raportu pojawi się w konsoli.

Logowanie, Steam Guard, wybór gry i obsługę lobby wykonujesz w oknach aplikacji.
Narzędzie nie odczytuje danych logowania. Jeśli zobaczysz `BLOCKED`, zachowaj raport:
to jest wynik danego etapu, a nie powód, aby zgadywać, czy test się udał.

Pierwszy eksperyment odpowiada na pytanie, czy dwa zwykłe klienty Steam/ATTILA
potrafią współpracować w tej konfiguracji. Po tym teście można włączyć w obu
launcherach identyczny zestaw MK1212 i powtórzyć te same kroki.

## Prerequisites and installation paths

- Windows with Windows PowerShell 5.1 or PowerShell 7, and working Sandboxie
  installed from its official distribution. The toolkit does not install drivers.
- Steam and ATTILA already installed normally. The ATTILA Steam application ID
  is `325610`; the detector reads library/app manifests, not account files.
- Two separate Steam accounts with access to two available copies for concurrent
  play. Steam Families does not turn one available copy into two concurrent copies.
- Disk space for two sandbox write layers and evidence. Existing installation
  assets can be read from their current library; sandboxed changes still use disk.

The tool looks for standard installation locations and registry/library records.
Use explicit paths if detection is incomplete. Run the same overrides for each
operation, or use a PowerShell variable containing the common parameters:

```powershell
$tool = 'D:\MK1212-DualClientTool\scripts\runtime\dual_client_lab.ps1'
$lab = @{
    LabRoot = 'D:\MK1212-DualClientLab'
    SteamRoot = 'D:\Steam'
    GameRoot = 'D:\SteamLibrary\steamapps\common\Total War Attila'
    SandboxieRoot = 'D:\Sandboxie-Plus'
}
& $tool -Mode Preflight @lab
& $tool -Mode Setup @lab
& $tool -Mode LaunchHost @lab
& $tool -Mode LaunchClient @lab
& $tool -Mode Collect @lab
```

These are examples: substitute the paths actually reported on the PC. The `.cmd`
runner uses the default paths when operated through its menu and can forward
explicit arguments from a command prompt. It starts only its child PowerShell
process with `-ExecutionPolicy Bypass`; it does not change machine/user execution
policy or grant administrator rights.

## Operations and ownership

| Mode | Effect | What the result establishes |
| --- | --- | --- |
| `Preflight` (default) | Discover dependencies and record a report in an owned lab root | Readiness or a specific missing prerequisite |
| `Setup` | Create two dedicated box configurations, read settings back, run isolated profile probes | Observed profile separation for this setup |
| `LaunchHost` | Revalidate ownership/configuration and request HOST Steam startup | A launch request, followed by actual process evidence when collected |
| `LaunchClient` | Revalidate ownership/configuration and request CLIENT Steam startup | The same boundary for the second role |
| `Collect` | Make a fresh evidence snapshot of the owned boxes | Observed processes, available executable identity and allowlisted logs |

The fixed box names are `MK1212LabHost` and `MK1212LabClient`. The lab root uses
`.mk1212-dual-client-lab.json` schema 1 and each box root has an ownership marker.
The script refuses a pre-existing unowned directory or conflicting box name.
It also refuses an unknown ownership schema. Repeated setup retains existing
profiles and previous evidence; it does not reset the experiment.

The initial ATTILA profiles are intentionally fresh. A directory-scoped
`WriteFilePath` rule hides the normal host profile from the sandbox and permits
each box to make its own profile. The tool does not copy existing saves or Steam
account settings. Enable the same desired mod list in each game's launcher when
moving from vanilla to MK1212; the tool does not certify mod parity automatically.

## Isolation and process evidence

Sandboxie command exit codes alone are not accepted as configuration proof.
`Setup` reads each required setting back, checks enabled-box enumeration, then
uses a boxed PowerShell probe to create a unique nonce file beneath the actual
ATTILA AppData profile. It looks for that exact marker under the owned physical
box root and checks that the normal profile did not receive it. It does not assume
that Sandboxie's on-disk AppData layout is universal.

Traversal is bounded and skips reparse points. Missing markers, contradictory
settings, conflicting ownership and exhausted discovery limits are explicit
failures or incomplete evidence. Probe files are small and retained as evidence;
the toolkit does not automatically clean boxes or terminate processes.

`Start.exe /box:<name> /listpids` has a count header, followed by one PID per line.
The parser requires a complete, numeric, nonduplicated result; `0` is valid but
empty stdout is not. Collection checks ATTILA process names, executable paths,
start times and box membership again to reduce PID-reuse races. Inaccessible
processes and missing identity fields remain explicit evidence limitations.

These observations establish neither Steam account identity nor a functioning
multiplayer session. Matching available executable SHA-256 hashes establish file
identity for those files only, not complete mod/load-order parity or license state.
One-PC testing also does not reproduce the network and scheduling conditions of
two independent computers.

## Evidence and privacy boundary

Each operation records a fresh timestamp/GUID report with schema and toolkit
source identity. A packaged run reads `source_sha` from `package_manifest.json`
and verifies the three executed PowerShell files against its hashes and lengths;
a mismatch blocks the operation. A checkout can use Git and records whether it
is dirty; an unavailable identity stays `unknown`. Steam and the Sandboxie CLI
executables also have their available file versions and hashes recorded.

The collector searches only owned sandbox trees. It copies a small filename
allowlist such as `MK1212_mp_debug.log`, `twdll.log`, `MK1212_log.txt`,
`PR45_RUNTIME_TRACE.txt`, `preferences.script.txt` and `user.script.txt`.
`MK1212_mp_debug.log` is opened by relative filename in MK1212, so its presence in
AppData is not assumed. Missing logs, skipped files and traversal/copy limits are
reported. The default per-file budget is 16 MiB and traversal budget is 20,000
entries. Each peer is additionally limited to 32 candidate files and 64 MiB of
captured data. Source files and previous snapshots are preserved.

Game binaries, saves and Steam account/credential files are not copied. Reports
and allowed logs may include Windows paths, machine/process information and
player/mod names; inspect a snapshot before sharing it. A filename allowlist
limits collection scope but cannot guarantee the contents of third-party logs.
No evidence is uploaded automatically.

Keep the report with both roles' logs. Record the game build, MK1212 commit/pack
hashes, complete mod order, HOST/CLIENT roles, turn/event and the observed result
when comparing an actual campaign. If debug logs are available, the repository's
existing comparator can assess shared semantic records:

```text
python scripts/ci/compare_mp_debug_logs.py HOST.log CLIENT.log
```

Matching logs are diagnostic evidence and do not replace the engine test.

## Runtime record to complete after the experiment

| Observation | Initial status | Required evidence |
| --- | --- | --- |
| Both profiles isolated | NOT RUN | Successful setup readback and two nonce probes |
| Two ATTILA processes | NOT RUN | Fresh collection with distinct PID/start-time/box identity |
| Separate Steam logins | NOT RUN | Operator observation; no account credentials collected |
| Shared multiplayer lobby | NOT RUN | HOST/CLIENT operator observation |
| Campaign loaded on both | NOT RUN | Both peers' turn/faction and available logs |
| One complete turn | NOT RUN | Both peers' outcomes and diagnostic comparison |
| Save/reload | NOT RUN | Same loaded turn/state on both peers and logs |
| MK1212 build/mod equality | NOT RUN | Exact build/pack hashes and complete load order |

The toolkit never converts `processes_observed` into multiplayer `PASS`.
If the second Steam login, ATTILA launch or lobby fails, preserve that negative
result and the exact component versions. Sandboxie compatibility is experimental;
its documentation explicitly says not all Steam games work sandboxed.

## Packaging and verification

The package is an external developer/operator tool. It contains only three
PowerShell sources, the `.cmd` runner, this guide and a schema-1 manifest.
Sandboxie and Steam remain separately installed dependencies; no upstream
executables, game assets, native MK1212 DLLs or runtime profiles are bundled.

The builder reads an explicit allowlist of committed Git blobs from the exact
checked-out SHA, rejects modified inputs, and records every payload's SHA-256.
Archive ordering, metadata and uncompressed storage are fixed, so the same source
produces the same ZIP bytes. Existing build directories are not overwritten.

```text
python scripts/ci/build_dual_client_lab.py --source-sha FULL_40_CHARACTER_HEAD_SHA
```

Windows CI executes synthetic behavior tests using Windows PowerShell 5.1 and
PowerShell 7 without Steam, ATTILA or Sandboxie. These tests cover parsing,
quoting, containment, bounds, evidence preservation and fail-closed prerequisites.
CI also verifies deterministic packaging and retains the normal repository/native
gates. A green CI/package does not establish runtime compatibility.

To stop the experiment, close the games and Steam normally. Preserve evidence
before removing the two dedicated boxes through Sandboxie's own interface.
The script provides no automatic reset, process termination or global settings
changes.

## Sources and authority

The implementation uses Sandboxie's documented launcher/configuration boundary;
native ATTILA modding APIs do not provide a second Windows/Steam session. This
small project-owned wrapper closes the setup/evidence gap and returns versioned
artifacts to this repository, following `docs/TOOLING_AUTHORITY.md`.

- [Sandboxie official downloads](https://sandboxie-plus.com/downloads/)
- [Start.exe command line](https://sandboxie-plus.com/sandboxie/startcommandline/)
- [SbieIni.exe command line](https://sandboxie-plus.com/sandboxie/sbieinicommandline/)
- [WriteFilePath isolation semantics](https://sandboxie-plus.com/sandboxie/writefilepath/)
- [FileRootPath](https://sandboxie-plus.com/sandboxie/filerootpath/)
- [Known conflicts / Steam](https://sandboxie-plus.com/sandboxie/knownconflicts/)
- [SbieIni query implementation](https://github.com/sandboxie-plus/Sandboxie/blob/master/Sandboxie/apps/ini/query.c)
- [SbieIni update implementation](https://github.com/sandboxie-plus/Sandboxie/blob/master/Sandboxie/apps/ini/update.c)
- [Start launcher implementation](https://github.com/sandboxie-plus/Sandboxie/blob/master/Sandboxie/apps/start/start.cpp)
- [Steam account concurrent use](https://help.steampowered.com/en/faqs/view/71EA-CDCE-FB5C-82B3)
- [Steam Families concurrent copies](https://help.steampowered.com/en/faqs/view/054C-3167-DD7F-49D4)

These are platform documentation/source references, not ATTILA-specific runtime
proof or publisher endorsement. The package manifest pins our wrapper revision;
the runtime report must separately identify installed dependencies and game files.
