from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


IGNORED_EVENTS = {
    "session_begin",
    "runtime",
}

IGNORED_FIELDS = {
    "seq",
    "local_faction",
    "role",
    "path",
    "existing_bytes",
}


def _split_escaped(line: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    escaped = False

    for char in line.rstrip("\r\n"):
        if escaped:
            current.append(
                {
                    "n": "\n",
                    "r": "\r",
                    "t": "\t",
                    "|": "|",
                    "\\": "\\",
                }.get(char, char)
            )
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == "|":
            parts.append("".join(current))
            current = []
        else:
            current.append(char)

    if escaped:
        current.append("\\")

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
    parts = _split_escaped(line)

    if not parts or parts[0] != "MKMP":
        raise ValueError(f"line {line_number}: not an MKMP record")

    fields: dict[str, str] = {}

    for part in parts[1:]:
        if "=" not in part:
            raise ValueError(f"line {line_number}: malformed field {part!r}")
        key, value = part.split("=", 1)
        if not key:
            raise ValueError(f"line {line_number}: empty field name")
        fields[key] = value

    if "event" not in fields:
        raise ValueError(f"line {line_number}: missing event")

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

    return True, f"PASS semantic_records={len(host)}"


def compare_files(host_path: str | Path, client_path: str | Path) -> tuple[bool, str]:
    return compare_records(load_log(host_path), load_log(client_path))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare MK1212 HOST/CLIENT structured MP debug logs."
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
