# MK1212 N2/N4 — native event probe and HOST coordinator

Status: **implemented experiment; Attila two-PC runtime proof NOT RUN**. Issue #69.
Use the exact source SHA and profile recorded in the accompanying pack manifest.
The current user plan is one consolidated verification after N4; no separate
manual campaign test is required after each preceding implementation step.

## What this delivery does

`scripts/network/mkmp_coordinator.py` is a Python 3.10+ standard-library HOST/CLIENT
application. It authenticates peers, compares their declared and hashed environment
identity, receives echo requests and bounded evidence, and persists receipt IDs so
a lost ACK or reconnect cannot create a second receipt. Optional candidate intents
are stored for inspection and can enter a bounded, frozen candidate batch. There
is **no Attila executor** in this program. The mod's HOST coordinator does not
replace or reconfigure Attila's underlying peer-to-peer campaign networking.

`common/mkmp_delivery_probe.lua` observes native campaign events and command
boundaries through the existing logger. Missing event/context/logger capabilities
fail softly. The probe adds no engine commands, timers, packet reader, native DLL
requirement, log replay or gameplay save fields. It owns ten listener IDs, one
save callback and one load callback, with 4,096 observations per local load segment
and a 65,535-segment bound; the main logger retains its independent global budget.

These are separate proofs:

| Result | What it establishes | What remains unproven |
| --- | --- | --- |
| Matching preflight digest | Same declared compatibility fields and hashed disk files | Actual loaded modules, effective engine load order, Steam ownership |
| Authenticated echo / `status=received` | Coordinator received that exact operation ID and payload | Application execution, campaign equality, engine packet delivery |
| `ready_for_phase_proof` batch | Both sidecars acknowledged the same frozen candidate list and digest | Lua delivery, player authorization, a safe shared engine phase |
| Matching native callback observations | Recorded event/context agrees in that capture | Unique operation identity and command replication semantics |
| Matching complete N1 checkpoints | Covered script components agree at the recorded boundary | Unobserved engine state or general absence of OOS |

## Native notification and diplomacy leads

The official [ATTILA event/context guide](https://wiki.totalwar.com/w/Total_War:_ATTILA_KIT_-_Extra_Scripting_Guides)
lists faction/key context for incidents and dilemmas, a choice for dilemma
decisions, and proposer/recipient plus several relationship flags for positive
diplomacy. It does not list a payment amount or unique deal ID in that diplomacy
context. Faction treasury is a current state value. The official
[campaign command guide](https://wiki.totalwar.com/w/Total_War:_ATTILA_KIT_-_Campaign_Script_Interface)
describes message display, keyed incident/dilemma triggers, custom dilemma choice
payloads and treasury modification. Those signatures do not establish arbitrary
Lua message delivery or multiplayer replication semantics.

The probe now captures these leads in the same final session:

| Native event | Observation | Evidence limit |
| --- | --- | --- |
| `IncidentOccuredEvent` | Faction and documented `dilemma()` key accessor | The spelling and accessor follow the official guide; unavailable access is recorded |
| `DilemmaIssued`, `DilemmaIssuedEvent` | Faction, key, exact event name | Guide and `lua_scripts/events.lua` disagree on naming; both are observed separately |
| `DilemmaChoiceMadeEvent` | Faction, dilemma key, choice | Context is not a unique action ID |
| `FactionRoundStart`, `FactionTurnStart`, `FactionBeginTurnPhaseNormal`, `FactionTurnEnd` | Actual owned-listener entry and faction | Does not claim to be the end of all listeners or a proven shared barrier |
| `PositiveDiplomaticEvent` | Proposer, recipient, available alliance/peace/access/trade/confederation flags, current treasuries | No inferred payment amount; all flags false does not prove a money-only deal |
| `DiplomaticOfferRejected` | Proposer, recipient, current treasuries | No accepted transaction or application ACK is inferred |

Local faction is logged separately in domain `local`; peer asymmetry there is
expected. Treasury snapshots are labelled `current_state_not_transaction_delta`.
The current vassal tracker correlates faction pairs and turn, so its pending pair
is also insufficient as a unique ID for repeated deals. The repository's diplomacy
option strings `payments` and `state gift` do not expose a scripting transport.

**Recommendation:** test native diplomacy first as a real engine transaction and
correlation source. A dedicated, side-effect-free keyed dilemma is the more direct
candidate for a small fixed instruction alphabet. Ordinary round-start notification
rendering is not yet a proven carrier. Native payment success does not establish
that `cm:treasury_mod` submits the same diplomatic command.

A future bounded native batch would need a pre-agreed operation catalogue, actor,
epoch, round, ordinal, complete-batch marker and payload reference. Both peers must
observe the same ordered batch and a proven application phase before the executor
may consume it. Fixed database keys could represent a limited symbol set; unknown
keys, localization text and arbitrary choice payload strings cannot be assumed to
cross the network. Dedicated records would also require appropriate DB packaging,
not just a Lua overlay. The current build neither encodes money as messages nor
adds hidden effects to existing notifications. The decisive missing observation is
one origin-side trigger or choice reaching the other peer with the same intended
kind, actor, choice and phase, followed by an exactly-once operation result.

## Protocol and persistence contract

Transport protocol 1 uses a four-byte big-endian frame length, canonical JSON and
HMAC-SHA256 with a generated 32-byte session key. The maximum frame is 65,536 bytes.
Unknown fields, duplicate JSON keys, unsupported schema, non-finite/floating-point
JSON values, bad tags and payload digests are rejected. A fresh challenge binds
each handshake to the selected HOST epoch and compatibility digest.

TLS 1.2 or newer is available with explicit certificates and normal hostname/CA
verification. `--trusted-lan` explicitly permits HMAC-authenticated plaintext on a
trusted LAN or existing private VPN; HMAC does not hide diagnostic contents. The
default HOST bind is loopback. No firewall rule, router forwarding, automatic
signalling, NAT traversal or Steam relay is installed by this program.

An operation ID is `(epoch, CLIENT, sequence)`. Sequence values are integers from
1 through 16,777,215, fitting Attila's actual float Lua ABI. Retries retain the same
ID and payload. Gaps, stale epochs, changed payloads under the same sequence and
expired receipts are rejected. HOST retains the latest 256 receipt digests;
older sequence numbers never become new work when their records expire.

HOST schema 1 records are written with copy/validate/flush/atomic-replace. CLIENT
persists an operation before transmission and commits its ACK and upload progress
in one state write. Each state directory has one process owner. Unknown/corrupt
state fails closed and is not reset automatically. IO failure does not advance
the in-memory receipt ledger. An ACK is emitted after durable receipt, never as
proof of a model mutation. No operation is automatically retried after an unknown
engine result because there is no engine execution path here.

Budgets: 128 inspection intents of at most 8 KiB, four uploaded logs of at most
16 MiB each, 64 MiB total received evidence, 24 KiB chunks, 4 MiB metadata, and
4,096 connections per HOST process by default (configurable up to 10,000). Export
verifies each chunk and whole-file SHA256. Invalid final data is rejected before
creating a new blob. File IDs use lowercase letters, digits, `_` and `-`; reserved
Windows names are rejected. Nothing silently truncates an oversized log.

Reconnect to the same campaign capture uses the same epoch and directories.
Loading a different campaign/save or starting a new capture requires **new HOST
and CLIENT directories and a new explicit epoch**. `init-host` generates a fresh
key and will not overwrite an existing session. Old evidence remains available;
old pending operations do not move into the new session. This is manual capture
ownership, not log-driven gameplay state.

### Buffered candidate batches

The buffer contains explicit inspection intents, never entries parsed out of
diagnostic logs. HOST freezes up to 32 accepted intents and 24 KiB in accepted
sender-sequence order. Each immutable batch includes epoch, batch ID, the fixed
member list `[HOST, CLIENT]`, count, full payloads and SHA256. At most eight batches
are retained. The network sender in this first implementation is CLIENT; the
`actor_faction` field is inspected metadata, not authenticated game-player identity.

HOST persists its receipt before returning the frozen list. CLIENT validates and
persists that complete list, then sends a separate digest/count acknowledgement.
Only then is the HOST record `ready_for_phase_proof`. There is no `execute` state.
Later arrivals are assigned to a later batch. The buffer does not flush because
0.5 seconds elapsed, a packet arrived, or the game displayed a notification.

An explicit `batch-abort` retains the frozen payload, digest, prior receipts and
reason. Nothing silently deletes accepted intents or replays them after abort.
Epoch, ordering, membership, digest, capacity or schema violations fail closed;
timeouts preserve the pending receipt request. A malformed already-pending
request requires inspection/new capture state, not changing its payload under
the same ID. Routine CLI validation catches empty batches, duplicated candidate
IDs and exhausted capacity before creating those requests.

For an optional helper-only buffer check during the same final run, create a small
UTF-8 JSON file such as `D:\MK1212\candidate.json`:

```json
{"kind":"PapalLoan","actor_faction":"REPLACE_WITH_FACTION_KEY","action_id":"inspection-1","phase":"inspection","data":{"purpose":"receipt_only"}}
```

Using the CLIENT arguments defined below:

```powershell
py -3 @mkmpClientArgs intent-candidate --intent D:\MK1212\candidate.json
py -3 @mkmpClientArgs batch-buffer
```

`batch-buffer` performs the two protocol steps in one CLI invocation. For separate
inspection, use `batch-freeze`, then `batch-ack --batch-id batch-1`. After an
interrupted freeze, `resume` first; if it completes the freeze, acknowledge the
returned batch ID. Explicit cancellation is:

```powershell
py -3 @mkmpClientArgs batch-abort --batch-id batch-1 --reason 'operator_cancelled'
```

These commands do not click a decision or perform a Papal loan in Attila.

## One consolidated two-PC run after N4

Use two genuine Steam Attila installations and the exact same selected pack/profile
and starting save. Keep the original non-Lua mod assets enabled. Follow the normal
pack installer guide first. All example working folders are on `D:`. Adjust the
actual game and pack names to those in this release.

### 1. Create the two preflight records

Place the four files from `scripts/network/` together in `D:\MK1212\network` on
both PCs. Use existing Python 3.10+; no pip packages are required. The included
`Run-MKMP-Coordinator.ps1` locates `py.exe -3` or `python.exe`; direct Python commands
below avoid dependence on PowerShell execution policy.

Create `D:\MK1212\load-order.txt` from the actual launcher configuration, in its
actual order. Supported entries are `mod "name.pack";` or one `.pack` path per
line. Relative paths resolve under the game's `data` directory. Absolute paths
also work for Workshop files. Do not substitute a directory listing: enabled
mods and their order are input evidence. Keep the exact launcher export or
screenshot with the result. Only one generated MK1212 script overlay may appear.

On HOST, for example:

```powershell
py -3 D:\MK1212\network\mkmp_coordinator.py preflight `
  --game-dir 'D:\SteamLibrary\steamapps\common\Total War Attila' `
  --manifest 'D:\MK1212\release\selected.manifest.json' `
  --pack 'D:\MK1212\release\mk1212_scripts_full_experimental_EXACT12.pack' `
  --load-order D:\MK1212\load-order.txt `
  --game-build 'COPY THE BUILD DISPLAYED BY ATTILA' --steam-branch public `
  --role HOST --save D:\MK1212\initial.save `
  --config-absent --native-absent --output D:\MK1212\HOST-preflight.json
```

Use the real manifest/pack filenames. If `empire.retail.dll` is elsewhere, add
`--retail-dll` with its actual path. Replace absence declarations with `--config`
and/or `--native-dll` when those files are present. For a new campaign, replace
`--save` with a shared descriptive `--new-campaign-key` containing the same scenario
and factions on both PCs. File absence is an explicit declaration, not automatic
module discovery. Both hash checks and source/profile identity must match.

Run the same command on CLIENT with its actual paths, `--role CLIENT` and output
`D:\MK1212\CLIENT-preflight.json`. Keep both JSON files. The output refuses to
overwrite an earlier record: use a new filename after changing the setup.

### 2. Initialize HOST and perform one echo/reconnect exercise

On HOST:

```powershell
py -3 D:\MK1212\network\mkmp_coordinator.py init-host `
  --state-dir D:\MK1212\n4-host-01 --identity D:\MK1212\HOST-preflight.json --epoch n4-capture-01
py -3 D:\MK1212\network\mkmp_coordinator.py host `
  --state-dir D:\MK1212\n4-host-01 --key-file D:\MK1212\n4-host-01\session-key.txt `
  --bind 0.0.0.0 --port 12124 --trusted-lan
```

Copy `session-key.txt` privately to the CLIENT. Keep it out of the final evidence
bundle. If Windows asks to allow Python on the private network, use only the
intended private network. No administrator permission is otherwise required.

On CLIENT, set reusable PowerShell arguments once, with the real HOST LAN address:

```powershell
$mkmpClientArgs = @(
  'D:\MK1212\network\mkmp_coordinator.py', 'client',
  '--state-dir', 'D:\MK1212\n4-client-01',
  '--key-file', 'D:\MK1212\session-key.txt',
  '--identity', 'D:\MK1212\CLIENT-preflight.json',
  '--epoch', 'n4-capture-01', '--host', '192.168.1.20', '--port', '12124', '--trusted-lan'
)
py -3 @mkmpClientArgs echo --text 'N4 capture 01'
```

`client_received_ack` with `meaning=received_not_applied` is the expected echo
result. For one reconnect check, stop the HOST helper with Ctrl+C, issue another
CLIENT echo with `--text 'N4 reconnect'`, then restart the same HOST command and
run `py -3 @mkmpClientArgs resume`. Exit 5 while HOST was stopped means the exact
pending request was retained. Reconnect changes neither epoch nor operation ID.
This brief exercise does not require disconnecting the Attila campaign itself.

For TLS instead, omit `--trusted-lan`: HOST takes `--cert`/`--cert-key`, CLIENT takes
`--ca`/`--server-name` matching the certificate. The tool does not create or silently
trust certificates. Certificate deployment and an actual TLS two-PC connection
remain separate environment proof if this optional mode is selected.

### 3. Capture the game paths in that same session

Start the shared disposable save/campaign after setup. Record one round start and
the native notifications that naturally occur. Exercise an existing native
player-to-player diplomatic payment once, with a clearly recorded small amount
and ordered proposer/recipient. Optionally reject the next ordinary offer to
capture the rejection event. Do not encode instructions in the payment amount.

Observe one existing dilemma and its choice when available; the passive probe
does not manufacture plague, sieges or Papal incidents. Click one Papal loan
decision through the new action path. If it reports an unproven delivery/phase
block, that is the specified evidence-only gate, not successful execution. Do not
enable or bypass a proof flag to make the test appear green. A round-start popup
on both screens is also insufficient: the two structured event records must agree.

End the turn and capture the next shared checkpoints. Save and reload once to
exercise the Lua state/load boundary. Keep this one planned capture together;
after reload, any new helper capture begins under a new explicit epoch as above.
If a native event did not occur naturally, report **NOT OBSERVED** rather than
adding repeated campaign sessions. A deliberate single-origin trigger experiment
needs a dedicated zero-effect record and remains pending until that content exists.

### 4. Upload, export and compare once

Exit Attila or copy its finished logs first; active changing files are rejected.
With HOST helper running, on CLIENT:

```powershell
py -3 @mkmpClientArgs collect --log 'D:\SteamLibrary\steamapps\common\Total War Attila\MK1212_mp_debug.log'
```

Use `resume` after interruption and repeat the same `collect` command on the same
unchanged file to finish remaining chunks. If native diagnostics were enabled,
collect `twdll.log` similarly. Logs remain opaque evidence bytes and are never read
back into either game's model.

Stop the HOST helper, then export on HOST to a new destination:

```powershell
py -3 D:\MK1212\network\mkmp_coordinator.py export `
  --state-dir D:\MK1212\n4-host-01 --output-dir D:\MK1212\N4-evidence-01 `
  --host-log 'D:\SteamLibrary\steamapps\common\Total War Attila\MK1212_mp_debug.log'
```

The export includes verified CLIENT files, the supplied HOST log, HOST preflight,
an evidence manifest, inspection intents and frozen batch evidence. Add CLIENT preflight plus the actual
launcher/load-order evidence and short scenario notes. Run the packaged N1
`compare_mp_debug_logs.py` once on the exported HOST and CLIENT MKMP logs. Keep
its complete status; incomplete checkpoints are not a PASS. Package the export
directory for review, not the live state directory containing the session key.

## CLI exit codes

| Exit | Meaning | Next action |
| --- | --- | --- |
| 0 | Requested local operation completed or receipt obtained | Read the result's evidence scope |
| 2 | Command line / Python requirement | Correct arguments or interpreter |
| 3 | Protocol, schema, authentication, state or budget rejection | Preserve files; correct the specific cause |
| 4 | File or durable IO failure | Preserve state; resolve IO before retrying |
| 5 | Network request still pending after bounded retries | Restore connection, then `resume` the same request |
| 6 | Preflight identity mismatch | Normalize source/profile/game/mod/save inputs |
| 130 | User interrupted helper | State and pending requests remain available |

The focused checks live in `scripts/ci/test_mp_transport.py`, including real local
TCP with loss of ACK, restart/dedup, gaps/conflicts, corrupt/future state, failed
durable writes, bounded evidence verification, preflight changes and the production
Lua observer. Run them with the integrated N4 validation, not between manual user
milestones. These checks establish repository behavior only; they do not run Attila.
