from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


IGNORED_EVENTS = {
    "session_begin",
    "runtime",
}

# Identity must match, but it does not demonstrate any shared campaign action.
IDENTITY_EVENTS = {"content_identity"}

IGNORED_FIELDS = {
    "seq",
    "local_faction",
    "role",
    "path",
    "existing_bytes",
}

SUPPORTED_SCHEMAS = {"1"}
REQUIRED_FIELDS = ("v", "seq", "turn", "event")


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

    return LogRecord(line_number=line_number, fields=fields)


def load_log(path: str | Path) -> list[LogRecord]:
    records: list[LogRecord] = []
    log_path = Path(path)

    for line_number, raw in enumerate(
        log_path.read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        if not raw.strip():
            continue
        records.append(parse_line(raw, line_number))

    return records


def _is_process_local_field(key: str) -> bool:
    lowered = key.lower()
    return (
        key in IGNORED_FIELDS
        or lowered in {"battle", "manager", "address", "pointer"}
        or lowered.endswith("_address")
        or lowered.endswith("_pointer")
    )


def semantic_records(records: Iterable[LogRecord]) -> list[SemanticRecord]:
    output: list[SemanticRecord] = []

    for record in records:
        if record.event in IGNORED_EVENTS:
            continue

        fields = tuple(
            sorted(
                (key, value)
                for key, value in record.fields.items()
                if key != "event" and not _is_process_local_field(key)
            )
        )
        output.append(
            SemanticRecord(
                event=record.event,
                fields=fields,
                source_line=record.line_number,
            )
        )

    return output


def compare_records(
    host_records: Iterable[LogRecord],
    client_records: Iterable[LogRecord],
) -> tuple[bool, str]:
    host = semantic_records(host_records)
    client = semantic_records(client_records)
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

    shared = min(len(host), len(client))

    for index in range(shared):
        host_record = host[index]
        client_record = client[index]

        if (
            host_record.event != client_record.event
            or host_record.fields != client_record.fields
        ):
            return (
                False,
                "FIRST DIVERGENCE "
                f"semantic_index={index} "
                f"host_line={host_record.source_line} "
                f"client_line={client_record.source_line} "
                f"HOST={host_record!r} "
                f"CLIENT={client_record!r}",
            )

    if len(host) != len(client):
        host_next = host[shared] if shared < len(host) else None
        client_next = client[shared] if shared < len(client) else None
        return (
            False,
            "FIRST DIVERGENCE "
            f"semantic_index={shared} "
            f"host_count={len(host)} client_count={len(client)} "
            f"HOST_NEXT={host_next!r} CLIENT_NEXT={client_next!r}",
        )

    if not host_actions or not client_actions:
        return insufficient_evidence()

    return (
        True,
        f"PASS semantic_records={len(host)} "
        "scope=instrumented_semantic_trace runtime_mp_proof=not_established",
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
