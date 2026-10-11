from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import hashlib
import math
from pathlib import Path
import re
from typing import Iterable
import zlib


IGNORED_EVENTS = {
    "session_begin",
    "runtime",
    "segment_begin",
}

# Identity must match, but it does not demonstrate any shared campaign action.
IDENTITY_EVENTS = {"content_identity"}

IGNORED_FIELDS = {
    "seq",
    "local_faction",
    "role",
    "path",
    "existing_bytes",
    "run_id",
}

SUPPORTED_SCHEMAS = {"1"}
REQUIRED_FIELDS = ("v", "seq", "turn", "event")
TRACE_DOMAINS = {"local", "shared_candidate", "transport", "state", "diagnostic"}
LOCAL_DOMAINS = {"local", "transport", "diagnostic"}
FINGERPRINT_SCHEMA = "mkfp-table-v1"
MAX_FINGERPRINT_BYTES = 65536
MAX_FINGERPRINT_ENTRIES = 16384
MAX_CHECKPOINT_BYTES = 262144
MAX_LOG_BYTES = 16777216


def _split_escaped(line: str, line_number: int = 1) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    escaped = False

    for char in line.rstrip("\r\n"):
        if escaped:
            escapes = {"n": "\n", "r": "\r", "t": "\t", "|": "|", "\\": "\\"}
            if char not in escapes:
                raise ValueError(
                    f"line {line_number}: unsupported escape {chr(92) + char!r}"
                )
            current.append(escapes[char])
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == "|":
            parts.append("".join(current))
            current = []
        else:
            current.append(char)

    if escaped:
        raise ValueError(f"line {line_number}: incomplete trailing escape")

    parts.append("".join(current))
    return parts


@dataclass(frozen=True)
class LogRecord:
    line_number: int
    fields: dict[str, str]

    @property
    def event(self) -> str:
        return self.fields.get("event", "unknown")

    @property
    def turn(self) -> str:
        return self.fields.get("turn", "unknown")


@dataclass(frozen=True)
class SemanticRecord:
    event: str
    fields: tuple[tuple[str, str], ...]
    source_line: int
    component_payload: str | None = field(default=None, repr=False, compare=False)


def parse_line(line: str, line_number: int = 1) -> LogRecord:
    parts = _split_escaped(line, line_number)

    if not parts or parts[0] != "MKMP":
        raise ValueError(f"line {line_number}: not an MKMP record")

    fields: dict[str, str] = {}

    for part in parts[1:]:
        if "=" not in part:
            raise ValueError(f"line {line_number}: malformed field {part!r}")
        key, value = part.split("=", 1)
        if not key:
            raise ValueError(f"line {line_number}: empty field name")
        if key in fields:
            raise ValueError(f"line {line_number}: duplicate field {key!r}")
        fields[key] = value

    missing = [key for key in REQUIRED_FIELDS if key not in fields]
    if missing:
        raise ValueError(
            f"line {line_number}: missing required fields: {', '.join(missing)}"
        )
    if fields["v"] not in SUPPORTED_SCHEMAS:
        raise ValueError(
            f"line {line_number}: unsupported log schema v={fields['v']!r}; "
            f"supported: {', '.join(sorted(SUPPORTED_SCHEMAS))}"
        )
    if not fields["event"]:
        raise ValueError(f"line {line_number}: empty event")
    if "trace_schema" in fields:
        if fields["trace_schema"] != "1":
            raise ValueError(f"line {line_number}: unsupported trace schema")
        for key in ("domain", "segment", "run_id"):
            if not fields.get(key):
                raise ValueError(f"line {line_number}: missing trace field {key!r}")
        if fields["domain"] not in TRACE_DOMAINS:
            raise ValueError(f"line {line_number}: unknown trace domain")
        _bounded_integer(fields["segment"], 0, 65535, "segment", line_number)
        _bounded_integer(fields["seq"], 1, 100000, "seq", line_number)

    return LogRecord(line_number=line_number, fields=fields)


def load_log(path: str | Path) -> list[LogRecord]:
    records: list[LogRecord] = []
    log_path = Path(path)
    if log_path.stat().st_size > MAX_LOG_BYTES:
        raise ValueError("log exceeds the 16 MiB output budget")

    contents = log_path.read_text(encoding="utf-8")
    for line_number, raw in enumerate(contents.splitlines(), start=1):
        if not raw.strip():
            continue
        records.append(parse_line(raw, line_number))

    if records and "trace_schema" in records[-1].fields and not contents.endswith("\n"):
        raise ValueError("truncated modern log: final record has no newline terminator")

    return records


def _bounded_integer(value: str, low: int, high: int, name: str, line: int) -> int:
    if not re.fullmatch(r"0|[1-9][0-9]*", value) or len(value) > 8:
        raise ValueError(f"line {line}: invalid {name}")
    number = int(value)
    if not low <= number <= high:
        raise ValueError(f"line {line}: {name} exceeds bounds")
    return number


def decode_fingerprint(payload: str) -> tuple[dict[str, str], int]:
    """Decode bounded data, never executable Lua. Preserve typed keys/bytes."""
    if not payload.isascii() or len(payload) > MAX_FINGERPRINT_BYTES:
        raise ValueError("fingerprint payload exceeds byte/ASCII contract")
    if not payload.startswith("MKFP1;"):
        raise ValueError("unknown fingerprint payload schema")
    offset, entries = 6, 0
    leaves: dict[str, str] = {}

    def count() -> None:
        nonlocal entries
        entries += 1
        if entries > MAX_FINGERPRINT_ENTRIES:
            raise ValueError("fingerprint entry budget exceeded")

    def length() -> int:
        nonlocal offset
        delimiter = payload.find(":", offset, offset + 9)
        if delimiter < 0:
            raise ValueError("fingerprint length frame is truncated")
        value = _bounded_integer(payload[offset:delimiter], 0, MAX_FINGERPRINT_BYTES,
                                 "fingerprint length", 0)
        offset = delimiter + 1
        return value

    def scalar() -> tuple[str, str]:
        nonlocal offset
        start = offset
        if offset >= len(payload):
            raise ValueError("truncated fingerprint scalar")
        kind = payload[offset]
        offset += 1
        if kind == "b":
            if offset >= len(payload) or payload[offset] not in "01":
                raise ValueError("invalid fingerprint boolean")
            value = "true" if payload[offset] == "1" else "false"
            offset += 1
        elif kind in {"s", "n"}:
            size = length()
            encoded_size = size * 2 if kind == "s" else size
            text = payload[offset:offset + encoded_size]
            if len(text) != encoded_size:
                raise ValueError("truncated fingerprint scalar body")
            offset += encoded_size
            if kind == "s":
                if not re.fullmatch(r"(?:[0-9a-f]{2})*", text):
                    raise ValueError("noncanonical fingerprint string bytes")
                raw = bytes.fromhex(text)
                try:
                    value = repr(raw.decode("utf-8"))
                except UnicodeDecodeError:
                    # Invalid UTF-8 bytes must not collide with a literal
                    # string containing the same backslash escape spelling.
                    value = "bytes:" + repr(raw)
            else:
                if not re.fullmatch(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:e[+-][0-9]+)?", text):
                    raise ValueError("invalid fingerprint number")
                number = float(text)
                if not math.isfinite(number) or (number == 0 and text != "0"):
                    raise ValueError("nonfinite/noncanonical fingerprint number")
                if format(number, ".17g") != text:
                    raise ValueError("noncanonical fingerprint number precision")
                value = text
        else:
            raise ValueError("unsupported fingerprint scalar type")
        return payload[start:offset], value

    def value(path: str, depth: int = 1) -> None:
        nonlocal offset
        count()
        if offset >= len(payload):
            raise ValueError("truncated fingerprint value")
        if payload[offset] != "m":
            token, display = scalar()
            # Keep the type in the value as well as the key path. String "1"
            # and number 1 are different campaign state.
            leaves[path] = token[0] + ":" + display
            return
        if depth > 16:
            raise ValueError("fingerprint depth budget exceeded")
        offset += 1
        size = length()
        previous = ""
        leaves[path] = "table" if size else "empty_table"
        for _ in range(size):
            count()
            token, display = scalar()
            if previous and token <= previous:
                raise ValueError("unordered/duplicate fingerprint map key")
            previous = token
            value(path + "[" + token[0] + ":" + display + "]", depth + 1)

    if offset >= len(payload) or payload[offset] != "m":
        raise ValueError("fingerprint root must be a table")
    value("$")
    if offset != len(payload):
        raise ValueError("trailing fingerprint bytes")
    return leaves, entries


def _is_process_local_field(key: str) -> bool:
    lowered = key.lower()
    return (
        key in IGNORED_FIELDS
        or lowered in {"battle", "manager", "address", "pointer"}
        or lowered.endswith("_address")
        or lowered.endswith("_pointer")
    )


def _normalize_records(
    records: Iterable[LogRecord],
) -> tuple[list[SemanticRecord], list[str], int]:
    output: list[SemanticRecord] = []
    problems: list[str] = []
    session, segment, previous_seq = 0, 0, 0
    modern_session = False
    identity_seen = False
    last_shared = ""
    session_checkpoints = 0
    total_checkpoints = 0
    last_checkpoint = 0
    checkpoint: dict[str, object] | None = None
    previous_payloads: dict[str, tuple[str, str]] = {}

    def finish_session() -> None:
        if checkpoint is not None:
            problems.append(f"session={session} segment={segment}: truncated checkpoint envelope")
        if modern_session:
            if not identity_seen:
                problems.append(f"session={session}: missing content identity")
            if not session_checkpoints:
                problems.append(f"session={session}: no complete checkpoint envelopes")
            if last_shared and last_shared != "checkpoint_end":
                problems.append(f"session={session}: shared trace tail has no closing checkpoint")

    for record in records:
        fields = dict(record.fields)
        modern = "trace_schema" in fields
        if record.event == "session_begin":
            finish_session()
            session += 1
            segment, previous_seq, last_checkpoint = 0, 0, 0
            modern_session = modern
            identity_seen = False
            session_checkpoints = 0
            last_shared = ""
            checkpoint = None
            previous_payloads = {}
            if modern and fields["segment"] != "0":
                problems.append(f"line {record.line_number}: new session must begin at segment 0")
        if modern:
            if not modern_session:
                problems.append(f"line {record.line_number}: modern trace lacks its session boundary")
            current_seq = int(fields["seq"])
            if current_seq != previous_seq + 1:
                problems.append(f"line {record.line_number}: sequence gap/repetition in process log")
            previous_seq = current_seq
            current_segment = int(fields["segment"])
            if record.event == "segment_begin":
                if checkpoint is not None:
                    problems.append(f"line {record.line_number}: load crossed an unfinished checkpoint")
                if current_segment != segment + 1:
                    problems.append(f"line {record.line_number}: missing/reordered load segment boundary")
                segment = current_segment
                checkpoint = None
                last_checkpoint = 0
                previous_payloads = {}
            elif current_segment != segment:
                problems.append(f"line {record.line_number}: segment changed without its boundary")
            fields["session_index"] = str(session)
            if fields.get("payload_rejected"):
                problems.append(f"line {record.line_number}: logger rejected reserved/invalid payload fields")
        elif modern_session:
            problems.append(f"line {record.line_number}: unversioned trace inserted into modern session")
        if record.event == "content_identity":
            identity_seen = True
        if record.event == "checkpoint_error":
            problems.append(f"line {record.line_number}: snapshot exception interrupted a checkpoint")

        component_payload = None
        if modern and record.event == "barrier":
            if checkpoint is not None:
                problems.append(f"line {record.line_number}: prior checkpoint has no end marker")
            identifier = _bounded_integer(fields.get("checkpoint", ""), 1, 100000,
                                          "checkpoint", record.line_number)
            count = _bounded_integer(fields.get("component_count", ""), 0, 16,
                                     "component_count", record.line_number)
            if identifier != last_checkpoint + 1:
                problems.append(f"line {record.line_number}: checkpoint ordinal gap/repetition")
            if fields["domain"] != "state" or not fields.get("stage") or not fields.get("listener"):
                problems.append(f"line {record.line_number}: barrier is missing its actual listener/stage")
            last_checkpoint = identifier
            checkpoint = {"id": str(identifier), "count": count, "components": set(), "bytes": 0}
        elif modern and record.event == "state_component":
            if checkpoint is None or fields.get("checkpoint") != checkpoint["id"]:
                problems.append(f"line {record.line_number}: component outside its checkpoint")
            component = fields.get("component", "")
            if not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", component):
                raise ValueError(f"line {record.line_number}: invalid state component name")
            if fields.get("schema") != FINGERPRINT_SCHEMA or fields.get("domain") != "state":
                raise ValueError(f"line {record.line_number}: unknown state component schema/domain")
            if checkpoint is not None:
                components = checkpoint["components"]
                assert isinstance(components, set)
                if component in components:
                    problems.append(f"line {record.line_number}: duplicate state component")
                components.add(component)
            status = fields.get("status")
            if status not in {"complete", "incomplete", "unavailable"}:
                raise ValueError(f"line {record.line_number}: unknown component status")
            if status != "complete" or fields.get("complete") != "true":
                previous_payloads.pop(component, None)
                problems.append(f"line {record.line_number}: component={component} status={status} "
                                f"reason={fields.get('reason', 'unspecified')}")
            else:
                mode = fields.get("payload_mode")
                if mode == "inline" and "payload" in fields and "payload_ref" not in fields:
                    component_payload = fields["payload"]
                elif mode == "unchanged" and "payload" not in fields:
                    prior = previous_payloads.get(component)
                    if prior is None or prior[0] != fields.get("payload_ref"):
                        problems.append(f"line {record.line_number}: missing/stale payload reference")
                    else:
                        component_payload = prior[1]
                else:
                    raise ValueError(f"line {record.line_number}: invalid component payload frame")
                if component_payload is not None:
                    _, entries = decode_fingerprint(component_payload)
                    expected_bytes = _bounded_integer(fields.get("bytes", ""), 0,
                                                      MAX_FINGERPRINT_BYTES, "bytes", record.line_number)
                    expected_entries = _bounded_integer(fields.get("entries", ""), 1,
                                                        MAX_FINGERPRINT_ENTRIES, "entries", record.line_number)
                    digest = f"adler32-v1:{zlib.adler32(component_payload.encode('ascii')) & 0xffffffff:08x}"
                    if expected_bytes != len(component_payload) or expected_entries != entries:
                        raise ValueError(f"line {record.line_number}: fingerprint size/entry mismatch")
                    if fields.get("checksum") != digest:
                        raise ValueError(f"line {record.line_number}: fingerprint checksum mismatch")
                    fields["payload_sha256"] = hashlib.sha256(component_payload.encode("ascii")).hexdigest()
                    previous_payloads[component] = (fields["checkpoint"], component_payload)
                    if checkpoint is not None:
                        checkpoint["bytes"] = int(checkpoint["bytes"]) + expected_bytes
                        if int(checkpoint["bytes"]) > MAX_CHECKPOINT_BYTES:
                            problems.append(f"line {record.line_number}: checkpoint byte budget exceeded")
            for key in ("payload", "payload_ref", "payload_mode"):
                fields.pop(key, None)
        elif modern and record.event == "checkpoint_end":
            count = _bounded_integer(fields.get("component_count", ""), 0, 16,
                                     "component_count", record.line_number)
            size = _bounded_integer(fields.get("bytes", ""), 0, MAX_CHECKPOINT_BYTES,
                                    "checkpoint bytes", record.line_number)
            if checkpoint is None or fields.get("checkpoint") != checkpoint["id"]:
                problems.append(f"line {record.line_number}: checkpoint end without matching start")
            else:
                if count != checkpoint["count"] or count != len(checkpoint["components"]):
                    problems.append(f"line {record.line_number}: missing/extra checkpoint components")
                if size != checkpoint["bytes"]:
                    problems.append(f"line {record.line_number}: checkpoint aggregate byte mismatch")
            if fields.get("complete") != "true" or fields.get("status") != "complete" or count < 1:
                problems.append(f"line {record.line_number}: checkpoint explicitly incomplete/empty")
            checkpoint = None
            session_checkpoints += 1
            total_checkpoints += 1

        if record.event in IGNORED_EVENTS or (
            fields.get("domain") in LOCAL_DOMAINS and record.event not in IDENTITY_EVENTS
        ):
            continue

        if record.event not in IDENTITY_EVENTS:
            last_shared = record.event
        semantic_fields = tuple(
            sorted(
                (key, value)
                for key, value in fields.items()
                if key != "event" and not _is_process_local_field(key)
            )
        )
        output.append(
            SemanticRecord(
                event=record.event,
                fields=semantic_fields,
                source_line=record.line_number,
                component_payload=component_payload,
            )
        )

    finish_session()
    return output, problems, total_checkpoints


def semantic_records(records: Iterable[LogRecord]) -> list[SemanticRecord]:
    """Projection only; compare_records also checks envelope completeness."""
    return _normalize_records(records)[0]


def _brief(record: SemanticRecord | None) -> str:
    if record is None:
        return "None"
    values = " ".join(f"{key}={value[:160]!r}" for key, value in record.fields)
    return f"{record.event}({values})"


def _correlation(record: SemanticRecord) -> tuple[str, ...]:
    fields = dict(record.fields)
    keys = ("session_index", "segment", "checkpoint", "component", "action_id",
            "intent_id", "parent_id", "actor", "stage")
    return (record.event, *(fields.get(key, "") for key in keys))


def _component_difference(host: SemanticRecord, client: SemanticRecord) -> str:
    if not host.component_payload or not client.component_payload:
        return ""
    left, _ = decode_fingerprint(host.component_payload)
    right, _ = decode_fingerprint(client.component_payload)
    keys = sorted(set(left) | set(right))
    for key in keys:
        if left.get(key) != right.get(key):
            return (f" component_path={key[:240]!r} "
                    f"HOST_VALUE={left.get(key, '<missing>')[:240]!r} "
                    f"CLIENT_VALUE={right.get(key, '<missing>')[:240]!r}")
    return ""


def compare_records(
    host_records: Iterable[LogRecord],
    client_records: Iterable[LogRecord],
) -> tuple[bool, str]:
    host, host_problems, host_checkpoints = _normalize_records(host_records)
    client, client_problems, client_checkpoints = _normalize_records(client_records)
    host_actions = sum(record.event not in IDENTITY_EVENTS for record in host)
    client_actions = sum(record.event not in IDENTITY_EVENTS for record in client)

    def insufficient_evidence() -> tuple[bool, str]:
        return (
            False,
            "INSUFFICIENT EVIDENCE "
            f"host_semantic_records={host_actions} client_semantic_records={client_actions}; "
            "both logs must contain shared semantic records; "
            "session/runtime bootstrap alone or with content identity does not "
            "establish shared execution",
        )

    if not host or not client:
        return insufficient_evidence()

    if host_problems or client_problems:
        details = [*("HOST " + item for item in host_problems[:3]),
                   *("CLIENT " + item for item in client_problems[:3])]
        return False, "INSUFFICIENT EVIDENCE " + "; ".join(details)

    shared = min(len(host), len(client))

    for index in range(shared):
        host_record = host[index]
        client_record = client[index]

        if (
            host_record.event != client_record.event
            or host_record.fields != client_record.fields
        ):
            correlation = _correlation(host_record)
            relocated = next((j for j in range(index + 1, min(len(client), index + 33))
                              if _correlation(client[j]) == correlation), None)
            order_note = "" if relocated is None else f" possible_shared_order_difference client_correlated_index={relocated}"
            return (
                False,
                "FIRST DIVERGENCE "
                f"semantic_index={index} "
                f"host_line={host_record.source_line} "
                f"client_line={client_record.source_line} "
                f"HOST={_brief(host_record)} "
                f"CLIENT={_brief(client_record)}"
                + _component_difference(host_record, client_record) + order_note,
            )

    if len(host) != len(client):
        host_next = host[shared] if shared < len(host) else None
        client_next = client[shared] if shared < len(client) else None
        return (
            False,
            "FIRST DIVERGENCE "
            f"semantic_index={shared} "
            f"host_count={len(host)} client_count={len(client)} "
            f"HOST_NEXT={_brief(host_next)} CLIENT_NEXT={_brief(client_next)}",
        )

    if not host_actions or not client_actions:
        return insufficient_evidence()

    return (
        True,
        f"PASS semantic_records={len(host)} "
        "scope=instrumented_semantic_trace runtime_mp_proof=not_established "
        f"complete_checkpoints={min(host_checkpoints, client_checkpoints)} "
        "state_scope=registered_components rng_coverage=wrapped_only",
    )


def compare_files(host_path: str | Path, client_path: str | Path) -> tuple[bool, str]:
    return compare_records(load_log(host_path), load_log(client_path))


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Compare MK1212 HOST/CLIENT structured semantic traces. "
            "A match alone does not establish runtime multiplayer proof."
        )
    )
    parser.add_argument("host_log")
    parser.add_argument("client_log")
    args = parser.parse_args()

    try:
        matched, message = compare_files(args.host_log, args.client_log)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"MK1212 MP log compare: ERROR: {exc}")
        return 2

    print(f"MK1212 MP log compare: {message}")
    return 0 if matched else 1


if __name__ == "__main__":
    raise SystemExit(main())
