# MK1212 multiplayer file debug log

Status: **implemented / runtime file location proof pending**  
Issue: #32  
Primary output: `MK1212_mp_debug.log`  
Schema: `1`  
Last reviewed: 2026-10-07

## Purpose

The multiplayer diagnostics layer writes a compact structured text log that a tester can send back after reproducing a problem.

The intended workflow is:

```text
play campaign
    |
    v
MK1212 Lua/runtime
    |
    +--> gameplay
    |
    +--> MK1212_mp_debug.log
             |
             v
      peer log comparator
```

The file is an **output sink only**.

Nothing in the log is loaded back into the campaign or used to decide gameplay.

## Safety contract

Logging must be strictly fail-soft.

If the file cannot be opened or written:

- file diagnostics disable themselves;
- gameplay continues through the normal path;
- no retry loop is started;
- no campaign mutation is rolled back because logging failed.

The logger has explicit budgets:

```text
max records: 100000
max bytes:   16777216 (16 MiB)
```

Existing log content is preserved. Initialization never opens the file with write/truncate mode.

If the existing file is already at the byte budget, logging is disabled with reason:

`existing_log_at_budget`

The user may archive/delete the file manually before the next test session.

## File location

The logger opens the relative filename:

`MK1212_mp_debug.log`

Therefore the concrete filesystem location is determined by Attila's process working directory.

The exact current-build path must be recorded during the first real runtime smoke rather than guessed in documentation.

## Record format

One record per line:

```text
MKMP|v=1|seq=17|turn=12|event=rng|maximum=30|minimum=16|result=24|token=common.heir_age:...
```

Core fields:

| Field | Meaning |
| --- | --- |
| `v` | log schema |
| `seq` | per-process successful-write sequence |
| `turn` | campaign turn when available |
| `event` | semantic record type |

Payload fields are sorted by key before writing.

Control characters and the pipe delimiter are escaped so each event remains exactly one physical line.

## Initial event coverage

### Session

`session_begin`

Contains local diagnostic metadata such as:

- log path;
- existing byte count;
- multiplayer flag;
- local faction if available.

These values are diagnostic and are ignored by the semantic peer comparator.

### Runtime / twdll

`runtime`

Mirrors the native-observability bootstrap state into the Lua-side file log.

A missing/incompatible DLL still leaves file logging available.

Runtime records themselves are not shared-gameplay evidence and are ignored by the default HOST/CLIENT semantic comparator.

### Campaign barriers

`barrier`

Initial barrier names:

- `faction_turn_start`
- `faction_turn_end`

When `MKMP_Runtime_Get_Campaign_Fingerprint()` is available, a barrier record may include its semantic fingerprint.

The logger does not require that function to exist.

### Campaign RNG

`rng`

Records:

- token;
- minimum;
- maximum;
- result.

Contract failures are recorded as `contract_error` before the existing fail-closed error path.

### Deferred region transfers

Events include:

- `region_transfer_queued`
- `region_transfer_duplicate`
- `region_transfer_apply`
- `contract_error` for queue overflow.

### Vassal reconciliation

`vassal`

Mirrors existing bounded reconciliation diagnostics into the structured file.

### Save output

`save_write`

Records only metadata:

- save key/name;
- schema;
- entry count;
- serialized byte count.

The complete save payload is **not** written to the debug log.

## twdll relationship

When twdll is available, runtime diagnostics may also be written to `twdll.log`.

The two channels serve different purposes:

```text
MK1212_mp_debug.log  -> semantic mod/campaign diagnostics
twdll.log            -> native/runtime diagnostics
```

Neither channel is gameplay authority.

## HOST / CLIENT comparison

Tool:

`scripts/ci/compare_mp_debug_logs.py`

Usage:

```powershell
python scripts/ci/compare_mp_debug_logs.py HOST_MK1212_mp_debug.log CLIENT_MK1212_mp_debug.log
```

Matching result:

```text
MK1212 MP log compare: PASS semantic_records=...
```

Divergence result:

```text
MK1212 MP log compare: FIRST DIVERGENCE semantic_index=...
```

The comparator ignores:

- session-start records;
- native runtime bootstrap records;
- per-process sequence values;
- local faction/role/path metadata;
- raw address/pointer fields.

It keeps shared semantic fields such as:

- turn;
- event;
- RNG token/result;
- save metadata;
- region transfer semantics;
- vassal diagnostics;
- campaign fingerprints when present.

## Evidence boundary

A matching pair of logs is useful evidence that the instrumented semantic sequence matched through the observed range.

It is not by itself proof that every engine state value is identical.

A mismatch should be treated as a first-divergence locator:

1. stop advancing the campaign;
2. preserve both logs;
3. preserve the triggering save when possible;
4. inspect the first differing semantic event;
5. reproduce from the nearest earlier barrier.

## Output-data rule

Debug logs are evidence artifacts.

The runtime therefore does not silently truncate an existing log on startup.

When the configured budget is reached, new writes stop rather than overwriting earlier evidence.
