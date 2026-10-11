# N0/N1: first observed divergence diagnostics

Issue: #69
Status: **REPO-OBSERVED implementation; exact-build Attila multiplayer proof pending**
Scope: supplements [MP_DEBUG_LOGGING.md](MP_DEBUG_LOGGING.md) with the N1 trace and component contract. The outer log format remains `v=1`; N1 records additionally declare `trace_schema=1`.

## What the repaired logger proves

The released War Weariness handler supplied a `turn` payload field while the real logger already owned `turn` in its record header. That produced duplicate fields, correctly rejected by the strict HOST/CLIENT parser. The fix removes the duplicate at the caller and reserves header fields in the logger. A caller cannot replace `v`, `seq`, `turn`, `event`, trace version, run identity, segment, or the wrapped RNG ordinal. Rejected fields are counted explicitly; they do not silently become evidence.

The production regression now executes real War Weariness, the real logger, the real canonical snapshot code and the strict Python parser together. Attila objects and file handles are doubles. This is a repository integration check, not an Attila multiplayer test.

File I/O, formatting, provider failures and snapshot limits remain diagnostic failures. They cannot consume RNG, cancel gameplay, retry a partially applied operation, or turn a log into a recovery journal. Existing files are appended to and never truncated by initialization.

## Runtime API and ownership

```lua
MKMP_Debug_Register_State_Provider("component_name", function()
    -- Return a NEW bounded plain table, never an engine interface or a mutable
    -- reference to the subsystem's actual campaign tables.
    return snapshot, "complete" -- or "incomplete" / "unavailable", reason
end)

MKMP_Debug_Trace("shared_candidate", "operation", {
    mechanic = "example", action_id = "captured-operation-id",
    actor = "faction_key", target = "region_key", stage = "requested"
})

MKMP_Debug_Barrier("faction_turn_start", {
    listener = "FactionTurnStart_Global", stage = "handler_entry"
})
```

Registration belongs to the subsystem initializer, after the diagnostics module is loaded. Provider names are stable lower-case identifiers. Duplicate registration does not replace a provider; repeating the identical callback is harmless. There are at most 16 providers. A provider must return a bounded copy, and must declare unavailable or incomplete state honestly. An absent subsystem is not automatically an observed empty subsystem.

`snapshot.complete == false` is also recognized as incomplete. Exceptions, nil, unsupported values, cycles, metatables and serialization limits produce unavailable or incomplete evidence. A valid empty table has its own encoding and remains distinct from nil.

The baseline region ownership provider enumerates the world region list and captures each region key and owning faction key. Equal faction region counts are insufficient: an ownership swap changes this component. A missing region/owner interface makes this component incomplete. In particular, a null owner during a raze/transition is reported as an observation gap, rather than silently represented as a valid empty owner.

War Weariness adds current values, event state, turns at war, the private faction/turn ledger and the passive increment. Its `completed_phase` field is the existing once guard, **claimed before model calls**; it does not certify the engine completed a partially failing command. The snapshot states this explicitly as `phase_semantics=claimed_before_model_call`.

The combined tranche registers the other active script providers from their owning initializers. Provider names and contents are part of each checkpoint's evidence, so differing provider sets cannot pass as identical coverage. The public API is diagnostic-only; no consumer may use its return values to choose a shared-model mutation.

### Operation completion state added during N4 integration

The `actions` component distinguishes `script_complete` (the owning Lua flags/decision state reached their requested value) from `confirmed` (the operation's captured result was observed). Neither label certifies native multiplayer delivery. Requested/interrupted actions are never replayed merely because a save loaded or a new turn began.

| Owner/provider | Persisted state and completion rule | Bounds and migration |
| --- | --- | --- |
| Buffer / `buffer` | V2 pending records carry their original action ID. Correlation matches the registry's exact original four-field payload before ownership can confirm that record. Timers consume only their owned action. | One pending record; V1 remains readable without inventing an ID; unconfirmed UI selection is not saved. |
| Annex / `annexation` | `MKMP_ANNEX_HANDOVERS` retains actor, target, command turn, phase and sorted captured region keys **before** `grant_faction_handover`. An exception leaves the claim uncertain across turns and loads. Later owner observations never reissue that command. `ownership_observed` covers those regions only, not armies, characters or complete native handover semantics. | Version 1; 128 claims, 128 regions per claim, 131,072 serialized bytes. A later validated annexation cycle can replace a claim only after its captured ownership was observed. Legacy absence defaults to no claimed command; it cannot retrospectively identify a pre-N4 partial handover. |
| Region trade / `region_trade` | `MKMP_REGION_TRADE_PENDING` retains the exact copied action payload and ID before transfers. Its SP turn observer requires `MKMP_Actions_Matches` plus every captured target owner, then confirms that ID and removes its observation record. Caller/UI mutations, a different region changing owner, an invalid ledger and external ACKs cannot satisfy that correlation. | Version 1; 32 pending operations, 32 regions per side, 131,072 serialized bytes. One unobserved trade per actor. Legacy absence defaults to no pending observation; UI selection is never promoted into a command. |

The two added mechanic loaders validate their complete next snapshots before replacing owned state. Unknown versions and malformed rows are refused. Load callbacks do not issue model commands. Their writers validate shape, identities, ordering and bounds before committing a payload through the common schema-3 codec; Attila still owns the outer save transaction.

## Domains, correlation and time boundaries

| Domain | Meaning | Default semantic comparison |
| --- | --- | --- |
| `local` | Local presentation, selection and intent observations | Excluded |
| `transport` | Receipt, queue, retry and ACK observations | Excluded |
| `diagnostic` | Bootstrap, segment markers and capability observations | Excluded, with structural errors still checked |
| `shared_candidate` | Observed script operation/callback whose delivery still needs runtime proof | Compared in order |
| `state` | Explicit component checkpoint | Compared after completeness validation |

`content_identity` is always compared. A local or diagnostic domain cannot hide a different source commit, pack profile or save schema.

Every modern record contains its local successful-write sequence, a process-local `run_id`, and a load `segment`. `run_id=append:<existing file bytes>` is only an output-stream label: it is not a shared session identifier, action identifier or random seed. The comparator ignores its value, preserves session boundaries, checks each process sequence for gaps/repetitions, and rejects missing/reordered load boundaries. A load segment resets checkpoint ordinals, wrapped RNG ordinals and payload-reference caches.

The registered load callback marks **entry into that diagnostics callback**. It does not claim all gameplay load callbacks have finished. The registered save checkpoint similarly means `save_callback_entry`, not an engine save transaction commit. Global faction-turn checkpoints are `handler_entry`, not a promise that all listeners for that event have completed. An operation should name its actual callback/listener and before/after/requested/observed stage.

Callers may attach `action_id`, `intent_id`, `parent_id`, actor, target and mechanic. The comparator uses these to explain a likely callback-order difference. It does not sort shared events into a passing order: different shared execution order may be precisely the desync source. Papal observer lifecycle ordinals remain `shared_candidate` evidence; they are not certified global battle IDs.

RNG records add an ordinal within the current load segment and `rng_coverage=wrapped_only`. Existing direct draws outside `MK1212_Random_Int` remain outside this observation. Checkpoints use `randomness_coverage=wrapped_only` to state the same limit. Diagnostics never make an extra draw to measure, seed or repair the stream.

## Canonical component format

The codec in `common/mkmp_fingerprint.lua` emits `mkfp-table-v1` with a `MKFP1;` payload prefix. It accepts plain Lua tables with string, finite-number or boolean keys and values, plus nested plain tables. It rejects executable values, engine interfaces, metatables and cycles.

| Token | Meaning |
| --- | --- |
| `m<count>:` followed by key/value pairs | Map; keys sorted by their encoded bytes |
| `s<byte_count>:<lowercase hex bytes>` | String; binary and UTF-8 bytes stay unambiguous |
| `n<text_length>:<number>` | Finite number, 17 significant digits, decimal separator normalized |
| `b0` / `b1` | False / true |

Numeric array indices preserve queue positions: swapping entries changes the key/value association, even when the entries have equal types. String key `"1"` and numeric key `1` are distinct. Empty strings, empty maps, false and zero are also distinct. Key sorting is bytewise and does not use Lua 5.1 locale-sensitive string ordering.

Each component declares schema, status, complete flag, encoded entry count, byte count and `adler32-v1:<8 hex digits>`. Adler-32 is calculated as two exact 16-bit halves so Attila's float-based Lua does not round away checksum bits. It is a diagnostic checksum, not a cryptographic content identity. The offline comparator also verifies the payload and computes SHA-256; first divergence can show the exact component key and its two values.

The logger includes a payload on the first complete observation or whenever its exact bytes change. An unchanged payload refers only to that component's previous complete checkpoint in the same session/load segment. The comparator must resolve and validate this reference. A missing, stale or cross-load reference cannot pass. This reduces repeated ownership-table output without discarding the payload needed for a key-level comparison.

## Checkpoint envelopes and budgets

A modern checkpoint is one `barrier` record, one `state_component` record per registered provider, then one `checkpoint_end` record. Start/end identifiers, component counts, unique component names and total captured bytes must agree. The terminal marker only commits the **diagnostic envelope**; it does not commit gameplay or acknowledge a network transaction.

| Budget | Limit |
| --- | ---: |
| Providers | 16 |
| Encoded nodes per component, including keys | 16,384 |
| Nested table depth | 16 |
| Encoded bytes per component | 65,536 |
| Complete component bytes per checkpoint | 262,144 |
| Payload fields per log record | 128 |
| Bytes per log record | 131,072 |
| Successful log records per process | 100,000 |
| Total log bytes, including existing content | 16,777,216 |
| Load segment ordinal | 65,535 |

The unchanged-payload cache is bounded by registered providers and component byte limits. It is cleared on each observed load boundary. Providers must also bound the work needed to obtain their copy: the serializer can reject an oversized returned value, but cannot preempt a provider that performs an unbounded traversal before returning.

An incomplete provider, failed envelope, missing terminal newline, sequence gap, unknown schema, corrupt checksum, stale reference, missing component or shared trace after the last closing checkpoint cannot produce a modern PASS. The comparator preserves the legacy `v=1` behavior for old logs without `trace_schema`; a legacy PASS retains its limited semantic-trace meaning.

A file cut exactly after a previously valid complete checkpoint is indistinguishable from a deliberately selected earlier observation range using only that file. The exact run range, final turn, external evidence manifest and both-peer collection are therefore still required. The tool detects structural truncation; it cannot infer unseen future records.

## Native and external identity boundary

The current native `core.GameBuild()` returns the name `Attila`, not an executable build/version. The adapter now reports this as `game_name`, keeps `game_build=unknown`, and marks exact environment identity as `external_preflight_required`.

`module_loaded` means Lua loaded the native module table. Native world readiness additionally requires a valid integer faction count in the bounded range 1–4096. A nil, nonnumeric or invalid count reports `world_capability_unavailable`; it does not advertise a ready world. Missing/incompatible native code does not disable Lua-owned ownership snapshots or ordinary gameplay.

The external N4 preflight owns actual executable and `empire.retail.dll` versions/hashes, pack manifest and load order, native DLL identity and save provenance. No logger reads these records back as gameplay authority. Matching `GameBuild()` names, source SHA alone or local protocol tests cannot replace exact-build two-peer evidence.

## Consolidated verification

`scripts/ci/test_mp_n1_diagnostics.py` executes one production-Lua fixture and reuses its output for focused parser/comparator cases: the real WW/logger collision path; local UI asymmetry; ownership swaps with equal counts; reserved fields; typed/binary/float canonical payloads; incomplete providers; truncation; checksum/reference failures; load segmentation; optional native capability failure; immutable WW snapshots; and logging failure without skipped/repeated gameplay.

`scripts/ci/test_mp_buffer_actions.py` now uses one consolidated Lua invocation for its original Buffer safety cases plus the real action registry, V1→V2 migration/correlation, MP capture-only isolation, Annex partial-handover claims across turns/save/load, and Region Trade exact ownership observation without replay. These fixtures use engine doubles and do not prove Attila multiplayer delivery.

Run this with the single consolidated post-N4 repository validation requested for this tranche. Test execution and exact-SHA outcomes belong in the release evidence, not an inferred runtime status in this document. Actual Attila timing, event delivery and shared-state equivalence require the final two-PC test.
