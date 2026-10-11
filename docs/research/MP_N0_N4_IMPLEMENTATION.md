# MK1212 N0–N4: action repair, first divergence and buffered receipts

Issue: [#69](https://github.com/karnalooch/MK1212Scripts/issues/69). Builds on the
script-action release at `3c2ae49265fe0abad140c7f8b1091b3c08d69ca5` / PR #67.

**Status: implemented experimental code, with repository validation reported for
the exact release SHA separately. Attila two-PC application proof is NOT RUN.**
The user's control result was that synchronization worked with scripts disabled.
That prioritizes local script actions, event ordering, RNG, timers and save state;
it does not by itself isolate the first divergent instruction or exclude a native
network fault. The source fixes and the transport experiment have separate proof
boundaries.

## Delivered scope

| Stage | Implementation | Remaining evidence |
| --- | --- | --- |
| N0 | War Weariness/logger field collision; Papal Lua errors and duplicate action lifecycle; stable nickname iteration and turn claims | Exact-build battle/event delivery on two PCs |
| N1 | Component snapshots, concrete region ownership, canonical fingerprints, full checkpoint envelopes, load segments, first-key comparator and covered RNG ordinals | Paired logs for the actual failing campaign; fingerprints cover declared components |
| N2 | Passive native incident, dilemma, turn-phase and diplomacy observations; explicit command-stage observations | Same origin-side operation delivered to both peers with a proven identity, phase and command effect |
| N3 | Captured local action registry, owner-specific decisions, Population reservations, Buffer State operations, region trades and annexation claims | An operation-specific native adapter before MP local intents can execute |
| N4 | Authenticated durable HOST/CLIENT receipts, exact environment preflight, reconnect, bounded evidence uploads and frozen candidate batches | Two-PC helper deployment; no Lua inbox, gameplay execution or replacement of Attila P2P |

N4 was implemented alongside the still-unproven N2 experiment at the user's
request. This is preparation for proving a channel, not evidence that Attila
requires or accepts this additional channel. **No configuration, incoming packet,
log file or experimental-profile flag can unlock the N3 MP action executor.**

## Captured actions and completion

`common/mkmp_actions.lua` copies plain scalar/table payloads with bytewise key
ordering and explicit bounds. UI selection references, live engine objects,
metatables, cycles and executable values cannot become action payloads. The
complete canonical arguments are used for comparison; a short checksum is only
a diagnostic label. The original actor/region/force/turn is retained rather than
read again from the current selection in a delayed callback.

In MP a local submission records a local diagnostic and returns
`native_delivery_and_command_semantics_unproven` before shared pending flags,
resources, RNG or engine mutations. The original game's button may still have
its own native effect: blocking the mod's Population accounting cannot claim to
cancel native recruitment or disbanding. The tooltip therefore describes the
scripted effect specifically. This limits the experimental profile's playability;
it is a candidate for focused investigation, not a finished synchronized campaign.

In SP, validated submissions claim their ID before a potentially partial effect.
Repeated identical captured arguments in the same turn cannot invoke it again.
An exception leaves `uncertain`; retry is not inferred from elapsed time or reload.
An owner can correlate an observed result with `MKMP_Actions_Matches`, which checks
kind, actor and the complete original payload against the valid action ledger.

| State | Meaning | Load/pruning policy |
| --- | --- | --- |
| `executing` | Claim exists; executor has not returned | Becomes `uncertain`; no replay |
| `requested` | A command or owned asynchronous operation awaits observation | Becomes `uncertain`; only owner-specific observation can resolve it |
| `uncertain` | A partial/unknown result must not be reissued | Persisted; blocks further actions of that kind and actor |
| `script_complete` | The expected local Lua bookkeeping transition was observed | Preserved; eligible for pruning after the preceding turn; **native effect remains unproven** |
| `confirmed` | The operation's documented local result was observed, such as exact ownership or a pure Lua reservation change | Preserved; eligible for pruning after the preceding turn; **not a remote replication claim** |

The ledger retains at most 128 records; counters stop at 1,000,000. Payloads are
bounded to 1,024 visited values, depth six and 16 KiB. Save capacity is reserved
before execution. Unresolved work is retained instead of silently discarded to
make room. Registered operations are capped at 32. These deliberate limits may
block an operation and require evidence review; they never wrap an ID.

Decisions use `(decision key, faction key)` identity. A removed/disabled decision,
or the exact Papal favour debit for a loan, can complete its local bookkeeping
without asserting treasury replication. Annex start/cancel similarly distinguishes
its Lua state from an engine bundle command. Deferred region transfer and handover
paths retain their own captured claims and do not acquire retry permission merely
because a new faction turn begins.

## Population accounting

Recruitment captures commander and force CQI, owner, region, horde status, unit
type, queue slot and queue revision. A reservation records its own original
region, population class, amount and action ID. Cancellation can refund that
record once; changing the selection or moving the commander cannot redirect it.

Force operations use the captured force instead of `LASTSELECTED_CHARACTER`.
Disband observation requires compatible surviving unit types and strengths before
calculating refunds. A vanished force or changed strength is not enough evidence
to invent a removed card. Merging cards does not refund manpower for a missing
merged card. Replacement commanders must have a valid bounded CQI and compatible
empty target accounting before a queue can move.

The official campaign unit interface does not document an individual unit CQI.
A repeated `UnitTrained` callback for two identical unit types therefore cannot
safely consume “the first matching reservation” twice. The affected commander's
accounting is preserved and marked uncertain until a proven reconciliation exists;
recruit/cancel do not treat its old slots as refundable identities. This policy
also applies in SP and is an explicit functional limitation of this experimental
accounting implementation. Battle-script unit identifiers are not imported as an
unproven campaign API. See the
[official Attila event/interface reference](https://wiki.totalwar.com/w/Total_War:_ATTILA_KIT_-_Extra_Scripting_Guides).

Legacy queues load with unknown reservation origins. The new code does not infer
where their debit occurred from the region in which a commander happens to stand
at load time. Those entries cannot authorize an unproven refund.

## Save compatibility and rollback

The common framing codec remains schema 3. Individual owners add explicit metadata:

| Owner | New data and compatibility |
| --- | --- |
| Actions | `MKMP_ACTIONS`, owned version 1; missing legacy ledger means no pending action, never replay |
| Buffer State | `MKMP_BUFFER_ACTION_STATE`, owned version 2, including action-ledger correlation; version 1 remains readable with no invented action ID |
| Decisions | Existing key/owner/enabled rows retained; owner-schema marker 1; versions 0/1 accepted and duplicate owners rejected |
| Population | `MKMP_POPULATION_RESERVATIONS`, owned version 1, with typed metadata, queues, reservations, phases and uncertainty; all required rows validate before assignment |
| Annexation | Versioned turn/handover metadata; a turn claim alone is insufficient to retry a partially completed native handover |
| Papal/nicknames | Bounded owner-specific battle/turn records; missing old metadata has deterministic documented defaults |

Readers reject unknown versions and malformed bounds. Owners stage a decoded
replacement before assignment. Where raw preservation is supported, corrupt or
future data remains blocked and is saved without guessing its meaning. These
guarantees are per owner: Attila's independent Lua callbacks are not a global
transaction spanning the entire save file.

Retain a campaign save and the matching mod set **from before this update**.
Rollback uses both that save and that mod set. Older readers do not understand
all new owner metadata, even if their common frame schema is also 3. Never switch
profiles on a continuing experimental save and call the result a compatibility
test. Historically lost decisions for a second owner cannot be reconstructed
from an already-deduplicated old list.

## Buffering in a P2P campaign

The implemented N4 buffer freezes a finite accepted intent list, its order,
membership, count and complete SHA256 digest. HOST records its receipt; CLIENT
persists the same list and sends a separate receipt. The highest state is
`ready_for_phase_proof`. Late arrivals go to a later batch; timeout retains pending
work. Abort preserves the frozen contents and its explicit reason.

This protocol currently has one CLIENT sender and a HOST coordinator. It does
not provide a second game-input stream, a native Attila receive hook or gameplay
player authentication. Its model can inform a later shared-phase adapter, but
receiving all bytes is only the first requirement. Both games must still expose
the same safe command boundary. A local half-second timer cannot supply that
boundary.

Native diplomatic money transfers are the preferred focused engine-path lead.
The current twdll `SetTreasury` is a direct field setter. It does not reveal the
accepted proposal/queued payment path. Incident/dilemma/turn events are observed
without mutating them. The actual dump was not located in accessible artifacts;
addresses and command IDs remain unknown. The source audit and next narrow
pass are in [MP_NATIVE_DIPLOMACY_CHANNEL.md](MP_NATIVE_DIPLOMACY_CHANNEL.md).

## Verification kept to one final stage

The user requested minimal intermediate testing. Implementation and independent
agent review therefore precede one consolidated final repository run. Required
repository gates remain intact; actual failures receive focused corrections and
rechecks. Final GitHub Actions results must name the delivered immutable SHA.

New Lua scenarios execute production modules with fake Attila boundaries, using
the repository's float-configured Lua runtime. They exercise actual bookkeeping,
save/load and injected partial failures; they do not simulate Steam packets or
prove engine callback semantics. N4 includes a real loopback TCP dropped-ACK and
reconnect scenario, which still is not a two-PC Attila run.

Use [MP_HOST_COORDINATOR.md](../runtime/MP_HOST_COORDINATOR.md) for the single
paired capture after N4: matching preflight, one echo/reconnect, native payment
and notification/dilemma observations, one save/load, then both complete logs.
The detailed negative controls are for that focused evidence session, not a
requirement to replay a campaign after every code edit.

Further implementation notes: [N0 Papal](MP_N0_PAPAL_ACTIONS.md),
[N1 diagnostics](MP_N1_DIAGNOSTICS.md), and
[pack installation](../runtime/PACK_RELEASE.md).
