"""MK1212 N4: bounded authenticated receipt transport, never game authority.

This module has no Lua, DLL, engine, command execution, or log replay interface.
An ACK means that a validated request was durably received by the coordinator.
It does not mean that either Attila process applied an action or has equal state.
"""
from __future__ import annotations

import base64
import copy
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import socket
import struct
import tempfile
from typing import Any


PROTOCOL = 1
STATE_SCHEMA = 1
MAX_SEQUENCE = 16_777_215  # All sequence integers fit the actual Lua float ABI.
MAX_FRAME = 65_536
MAX_STATE_BYTES = 4 * 1024 * 1024
MAX_RECENT = 256
MAX_INTENTS = 128
MAX_BATCHES = 8
MAX_BATCH_ITEMS = 32
MAX_BATCH_BYTES = 24 * 1024
MAX_LOG_BYTES = 16 * 1024 * 1024
MAX_EVIDENCE_BYTES = 64 * 1024 * 1024
MAX_CHUNK = 24 * 1024
MAX_LOG_FILES = 4
MAX_IDENTIFIER = 96
IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,96}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
AUTHORITY = "evidence_only"
LOG_NAMES = {"MK1212_mp_debug.log", "twdll.log"}


class ProtocolError(ValueError):
    """Expected reject with a short, non-secret reason suitable for the CLI."""


def identifier(value: Any, name: str = "identifier") -> str:
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise ProtocolError(f"invalid_{name}")
    return value


def file_identifier(value: Any) -> str:
    # Evidence IDs become export directory names, so the general protocol ID
    # alphabet (which permits ':' and '.') is deliberately not used here.
    if not isinstance(value, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,95}", value):
        raise ProtocolError("invalid_file_id_use_lowercase_letters_digits_underscore_dash")
    if value in {"con", "prn", "aux", "nul", *(f"com{n}" for n in range(1, 10)), *(f"lpt{n}" for n in range(1, 10))}:
        raise ProtocolError("reserved_file_id")
    return value


def integer(value: Any, lower: int, upper: int, name: str) -> int:
    if type(value) is not int or not lower <= value <= upper:
        raise ProtocolError(f"invalid_{name}")
    return value


def digest(value: Any) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def _utf8_size(value: str) -> int:
    try:
        return len(value.encode("utf-8"))
    except UnicodeError as error:
        # JSON permits escaped lone surrogates. They are not valid UTF-8 text
        # and must remain an ordinary protocol rejection, including before
        # authentication, rather than terminating the listening process.
        raise ProtocolError("invalid_unicode_text") from error


def _validate_json(value: Any, depth: int = 0) -> None:
    if depth > 12:
        raise ProtocolError("json_depth_budget")
    if value is None or type(value) is bool:
        return
    if type(value) is int:
        # Byte budgets and file sizes are transport metadata, never Lua input.
        # The operation sequence itself has the stricter Lua-float bound below.
        if abs(value) > 9_007_199_254_740_991:
            raise ProtocolError("json_integer_outside_exact_range")
        return
    if isinstance(value, str):
        if _utf8_size(value) > MAX_FRAME:
            raise ProtocolError("json_string_budget")
        return
    if isinstance(value, list):
        if len(value) > 4096:
            raise ProtocolError("json_array_budget")
        for item in value:
            _validate_json(item, depth + 1)
        return
    if isinstance(value, dict):
        if len(value) > 4096:
            raise ProtocolError("json_object_budget")
        for key, item in value.items():
            if not isinstance(key, str) or _utf8_size(key) > 192:
                raise ProtocolError("json_key_budget")
            _validate_json(item, depth + 1)
        return
    raise ProtocolError("json_type_not_supported")


def canonical(value: Any) -> bytes:
    _validate_json(value)
    return json.dumps(value, sort_keys=True, ensure_ascii=True,
                      separators=(",", ":"), allow_nan=False).encode("ascii")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("duplicate_json_key")
        result[key] = value
    return result


def strict_json(data: bytes, max_bytes: int = MAX_FRAME) -> Any:
    if len(data) > max_bytes:
        raise ProtocolError("json_byte_budget")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_unique_object,
                           parse_constant=lambda _: (_ for _ in ()).throw(
                               ProtocolError("non_finite_json")))
    except ProtocolError:
        raise
    except (ValueError, RecursionError) as error:
        # ValueError also covers Python's bounded decimal-integer conversion
        # and Unicode decoding errors, neither of which is JSONDecodeError.
        raise ProtocolError("invalid_json") from error
    _validate_json(value)
    return value


def exact_fields(value: Any, fields: set[str], name: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ProtocolError(f"invalid_{name}_fields")
    return value


def validate_intent(payload: Any) -> dict[str, Any]:
    exact_fields(payload, {"kind", "actor_faction", "action_id", "phase", "data"}, "intent")
    for key in ("kind", "actor_faction", "action_id", "phase"):
        identifier(payload[key], key)
    if not isinstance(payload["data"], dict) or len(canonical(payload)) > 8192:
        raise ProtocolError("intent_payload_budget")
    return payload


def read_key(path: Path) -> bytes:
    if path.stat().st_size > 128:
        raise ProtocolError("key_file_budget")
    try:
        value = path.read_text(encoding="ascii").strip()
    except (UnicodeError, OSError) as error:
        raise ProtocolError("key_file_unreadable") from error
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ProtocolError("key_must_be_32_random_bytes_as_lowercase_hex")
    return bytes.fromhex(value)


def encode_frame(message: dict[str, Any], key: bytes) -> bytes:
    body = canonical(message)
    tag = hmac.new(key, body, hashlib.sha256).hexdigest()
    encoded = canonical({"message": message, "hmac_sha256": tag})
    if len(encoded) > MAX_FRAME:
        raise ProtocolError("frame_budget")
    return struct.pack("!I", len(encoded)) + encoded


def receive_exact(stream: socket.socket, length: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < length:
        data = stream.recv(length - len(chunks))
        if not data:
            raise ConnectionError("peer_closed_before_complete_frame")
        chunks.extend(data)
    return bytes(chunks)


def receive_frame(stream: socket.socket, key: bytes) -> dict[str, Any]:
    length = struct.unpack("!I", receive_exact(stream, 4))[0]
    if length < 2 or length > MAX_FRAME:
        raise ProtocolError("frame_budget")
    envelope = exact_fields(strict_json(receive_exact(stream, length)),
                            {"message", "hmac_sha256"}, "envelope")
    tag = envelope["hmac_sha256"]
    if not isinstance(tag, str) or not SHA256.fullmatch(tag):
        raise ProtocolError("invalid_authentication_tag")
    body = canonical(envelope["message"])
    expected = hmac.new(key, body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(tag, expected):
        raise ProtocolError("authentication_failed")
    if not isinstance(envelope["message"], dict):
        raise ProtocolError("message_must_be_object")
    return envelope["message"]


def send_frame(stream: socket.socket, message: dict[str, Any], key: bytes) -> None:
    stream.sendall(encode_frame(message, key))


def atomic_bytes(path: Path, data: bytes, *, replace: bool = True) -> None:
    """Flush a complete temporary file before replacing the previous version."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if not replace and path.exists():
        raise ProtocolError("output_already_exists")
    temporary: str | None = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        if not replace and path.exists():
            raise ProtocolError("output_already_exists")
        os.replace(temporary, path)
        temporary = None
        # Directory fsync is supported on POSIX; Windows replacement is atomic
        # but directory handles are not accepted by os.open/fsync there.
        if os.name != "nt":
            directory_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def atomic_json(path: Path, value: Any, *, replace: bool = True) -> None:
    data = canonical(value)
    if len(data) > MAX_STATE_BYTES:
        raise ProtocolError("state_byte_budget")
    atomic_bytes(path, data + b"\n", replace=replace)


def load_json(path: Path) -> Any:
    if path.stat().st_size > MAX_STATE_BYTES:
        raise ProtocolError("state_byte_budget")
    return strict_json(path.read_bytes(), MAX_STATE_BYTES)


class DirectoryLock:
    """One coordinator/client owner per state directory, including on Windows."""

    def __init__(self, directory: Path):
        self.directory = directory
        self.stream = None

    def __enter__(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        self.stream = (self.directory / "owner.lock").open("a+b")
        if self.stream.seek(0, os.SEEK_END) == 0:
            self.stream.write(b"0")
            self.stream.flush()
        self.stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self.stream.close()
            self.stream = None
            raise ProtocolError("state_directory_in_use") from error
        return self

    def __exit__(self, *_):
        if self.stream is not None:
            if os.name == "nt":
                import msvcrt
                self.stream.seek(0)
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
            self.stream.close()


def validate_request(value: Any, epoch: str) -> dict[str, Any]:
    request = exact_fields(value, {"type", "protocol", "epoch", "actor", "sequence",
                                   "kind", "payload", "payload_sha256"}, "request")
    if request["type"] != "request" or type(request["protocol"]) is not int or request["protocol"] != PROTOCOL:
        raise ProtocolError("unsupported_protocol")
    if request["epoch"] != epoch:
        raise ProtocolError("stale_or_unknown_epoch")
    if request["actor"] != "CLIENT":
        raise ProtocolError("invalid_actor")
    integer(request["sequence"], 1, MAX_SEQUENCE, "sequence")
    if not isinstance(request["kind"], str) or request["kind"] not in {"echo", "evidence_part", "intent_candidate", "batch_freeze", "batch_ack", "batch_abort"}:
        raise ProtocolError("unsupported_request_kind")
    if not isinstance(request["payload"], dict):
        raise ProtocolError("payload_must_be_object")
    if request["payload_sha256"] != digest(request["payload"]):
        raise ProtocolError("payload_digest_mismatch")
    return request


def make_request(epoch: str, sequence: int, kind: str, payload: dict[str, Any]) -> dict[str, Any]:
    return validate_request({"type": "request", "protocol": PROTOCOL, "epoch": epoch,
                             "actor": "CLIENT", "sequence": sequence, "kind": kind,
                             "payload": copy.deepcopy(payload), "payload_sha256": digest(payload)}, epoch)


def validate_batch(batch: Any, epoch: str) -> None:
    exact_fields(batch, {"frozen", "batch_sha256", "host_seen", "client_seen", "state", "abort_reason"}, "batch")
    frozen = batch["frozen"]
    exact_fields(frozen, {"schema", "epoch", "batch_id", "members", "count", "items"}, "frozen_batch")
    if type(frozen["schema"]) is not int or frozen["schema"] != 1 or frozen["epoch"] != epoch:
        raise ProtocolError("unsupported_or_stale_batch")
    identifier(frozen["batch_id"], "batch_id")
    if frozen["members"] != ["HOST", "CLIENT"]:
        raise ProtocolError("batch_membership_changed")
    items = frozen["items"]
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_BATCH_ITEMS or type(frozen["count"]) is not int or frozen["count"] != len(items):
        raise ProtocolError("batch_item_budget_or_count")
    last = 0
    for item in items:
        exact_fields(item, {"sender", "sender_sequence", "payload_sha256", "payload"}, "batch_item")
        if item["sender"] != "CLIENT":
            raise ProtocolError("unsupported_batch_sender")
        sequence = integer(item["sender_sequence"], 1, MAX_SEQUENCE, "batch_sender_sequence")
        if sequence <= last:
            raise ProtocolError("batch_order_or_duplicate_sequence")
        validate_intent(item["payload"])
        if item["payload_sha256"] != digest(item["payload"]):
            raise ProtocolError("batch_payload_digest_mismatch")
        last = sequence
    if len(canonical(frozen)) > MAX_BATCH_BYTES or batch["batch_sha256"] != digest(frozen):
        raise ProtocolError("batch_digest_or_byte_budget")
    if batch["host_seen"] is not True or type(batch["client_seen"]) is not bool:
        raise ProtocolError("invalid_batch_receipts")
    if not isinstance(batch["state"], str) or batch["state"] not in {"awaiting_client_receipt", "ready_for_phase_proof", "aborted"}:
        raise ProtocolError("unsupported_batch_state_no_execution_transition")
    if batch["state"] == "awaiting_client_receipt" and batch["client_seen"]:
        raise ProtocolError("batch_state_receipt_conflict")
    if batch["state"] == "ready_for_phase_proof" and not batch["client_seen"]:
        raise ProtocolError("batch_missing_client_receipt")
    if not isinstance(batch["abort_reason"], str) or len(batch["abort_reason"].encode("utf-8")) > 192:
        raise ProtocolError("batch_abort_reason_budget")
    if (batch["state"] == "aborted") != bool(batch["abort_reason"]):
        raise ProtocolError("batch_abort_state_conflict")


class HostStore:
    """Receipt ledger with copy/validate/flush/swap and no application executor."""

    def __init__(self, directory: Path):
        self.directory = directory
        self.path = directory / "host-state.json"
        self.state = load_json(self.path)
        self._validate_state(self.state)

    @staticmethod
    def create(directory: Path, epoch: str, identity_sha256: str) -> "HostStore":
        identifier(epoch, "epoch")
        if not isinstance(identity_sha256, str) or not SHA256.fullmatch(identity_sha256):
            raise ProtocolError("invalid_identity_digest")
        state = {"schema": STATE_SCHEMA, "protocol": PROTOCOL, "authority": AUTHORITY,
                 "epoch": epoch, "identity_sha256": identity_sha256, "last_sequence": 0,
                 "recent": [], "intents": [], "evidence": {}, "evidence_bytes": 0,
                 "batches": [], "last_batched_sequence": 0}
        atomic_json(directory / "host-state.json", state, replace=False)
        return HostStore(directory)

    @staticmethod
    def _validate_state(state: Any) -> None:
        exact_fields(state, {"schema", "protocol", "authority", "epoch", "identity_sha256",
                             "last_sequence", "recent", "intents", "evidence", "evidence_bytes",
                             "batches", "last_batched_sequence"},
                     "host_state")
        if type(state["schema"]) is not int or state["schema"] != STATE_SCHEMA or type(state["protocol"]) is not int or state["protocol"] != PROTOCOL:
            raise ProtocolError("unsupported_state_schema")
        if state["authority"] != AUTHORITY:
            raise ProtocolError("unsupported_authority")
        identifier(state["epoch"], "epoch")
        if not isinstance(state["identity_sha256"], str) or not SHA256.fullmatch(state["identity_sha256"]):
            raise ProtocolError("invalid_identity_digest")
        last = integer(state["last_sequence"], 0, MAX_SEQUENCE, "last_sequence")
        recent = state["recent"]
        if not isinstance(recent, list) or len(recent) != min(last, MAX_RECENT):
            raise ProtocolError("invalid_receipt_history")
        for index, item in enumerate(recent, max(1, last - MAX_RECENT + 1)):
            exact_fields(item, {"sequence", "request_sha256", "ack"}, "receipt")
            if type(item["sequence"]) is not int or item["sequence"] != index or not isinstance(item["request_sha256"], str) or not SHA256.fullmatch(item["request_sha256"]):
                raise ProtocolError("corrupt_receipt_history")
            ack = item["ack"]
            exact_fields(ack, {"type", "protocol", "epoch", "sequence", "request_sha256", "status", "authority", "duplicate", "result"}, "stored_ack")
            if ack["type"] != "ack" or type(ack["protocol"]) is not int or ack["protocol"] != PROTOCOL or type(ack["sequence"]) is not int or ack["sequence"] != index or ack["duplicate"] is not False or ack["authority"] != AUTHORITY or ack["status"] != "received" or ack["epoch"] != state["epoch"] or ack["request_sha256"] != item["request_sha256"] or not isinstance(ack["result"], dict):
                raise ProtocolError("corrupt_receipt_ack")
        if not isinstance(state["intents"], list) or len(state["intents"]) > MAX_INTENTS:
            raise ProtocolError("intent_budget")
        intent_ids = set()
        last_intent = 0
        for intent in state["intents"]:
            exact_fields(intent, {"sequence", "authority", "status", "payload"}, "stored_intent")
            sequence = integer(intent["sequence"], 1, last, "intent_sequence")
            if sequence <= last_intent:
                raise ProtocolError("stored_intent_order_conflict")
            last_intent = sequence
            if intent["authority"] != AUTHORITY or intent["status"] != "inspection_only":
                raise ProtocolError("corrupt_intent")
            payload = validate_intent(intent["payload"])
            if payload["action_id"] in intent_ids:
                raise ProtocolError("duplicate_stored_intent")
            intent_ids.add(payload["action_id"])
        if not isinstance(state["batches"], list) or len(state["batches"]) > MAX_BATCHES:
            raise ProtocolError("batch_count_budget")
        last_batched = 0
        intent_map = {item["sequence"]: item["payload"] for item in state["intents"]}
        for index, batch in enumerate(state["batches"], 1):
            validate_batch(batch, state["epoch"])
            if batch["frozen"]["batch_id"] != f"batch-{index}":
                raise ProtocolError("batch_id_order_conflict")
            for item in batch["frozen"]["items"]:
                if item["sender_sequence"] <= last_batched or intent_map.get(item["sender_sequence"]) != item["payload"]:
                    raise ProtocolError("batch_does_not_match_accepted_intents")
                last_batched = item["sender_sequence"]
        if type(state["last_batched_sequence"]) is not int or state["last_batched_sequence"] != last_batched:
            raise ProtocolError("invalid_last_batched_sequence")
        evidence = state["evidence"]
        if not isinstance(evidence, dict) or len(evidence) > MAX_LOG_FILES:
            raise ProtocolError("evidence_file_budget")
        total = 0
        for file_id, file in evidence.items():
            file_identifier(file_id)
            exact_fields(file, {"name", "file_sha256", "total_bytes", "received_bytes", "parts"}, "evidence_file")
            if not isinstance(file["name"], str) or file["name"] not in LOG_NAMES or not isinstance(file["file_sha256"], str) or not SHA256.fullmatch(file["file_sha256"]):
                raise ProtocolError("corrupt_evidence_identity")
            maximum = integer(file["total_bytes"], 1, MAX_LOG_BYTES, "total_bytes")
            received = integer(file["received_bytes"], 0, maximum, "received_bytes")
            if not isinstance(file["parts"], list) or len(file["parts"]) > 1024:
                raise ProtocolError("evidence_part_budget")
            size = 0
            for part in file["parts"]:
                exact_fields(part, {"sha256", "bytes"}, "evidence_part")
                if not isinstance(part["sha256"], str) or not SHA256.fullmatch(part["sha256"]):
                    raise ProtocolError("invalid_evidence_digest")
                size += integer(part["bytes"], 1, MAX_CHUNK, "part_bytes")
            if size != received:
                raise ProtocolError("corrupt_evidence_size")
            total += received
        if type(state["evidence_bytes"]) is not int or state["evidence_bytes"] != total or total > MAX_EVIDENCE_BYTES:
            raise ProtocolError("corrupt_evidence_total")

    def hello(self, message: Any, challenge: str) -> dict[str, Any]:
        exact_fields(message, {"type", "protocol", "epoch", "actor", "challenge", "identity_sha256", "authority"}, "hello")
        if message["type"] != "hello" or type(message["protocol"]) is not int or message["protocol"] != PROTOCOL:
            raise ProtocolError("unsupported_protocol")
        if message["epoch"] != self.state["epoch"]:
            raise ProtocolError("stale_or_unknown_epoch")
        if message["actor"] != "CLIENT" or message["challenge"] != challenge:
            raise ProtocolError("invalid_handshake")
        if message["authority"] != AUTHORITY:
            raise ProtocolError("unsupported_authority")
        if message["identity_sha256"] != self.state["identity_sha256"]:
            raise ProtocolError("preflight_identity_mismatch")
        return {"type": "ready", "protocol": PROTOCOL, "epoch": self.state["epoch"],
                "authority": AUTHORITY, "identity_sha256": self.state["identity_sha256"],
                "last_sequence": self.state["last_sequence"]}

    def receive(self, value: Any) -> dict[str, Any]:
        request = validate_request(value, self.state["epoch"])
        sequence = request["sequence"]
        request_sha = digest(request)
        last = self.state["last_sequence"]
        if sequence <= last:
            previous = next((item for item in self.state["recent"] if item["sequence"] == sequence), None)
            if previous is None:
                raise ProtocolError("expired_receipt_no_replay")
            if request_sha != previous["request_sha256"]:
                raise ProtocolError("sequence_payload_conflict")
            return copy.deepcopy(dict(previous["ack"], duplicate=True))
        if sequence != last + 1:
            raise ProtocolError("sequence_gap")
        candidate = copy.deepcopy(self.state)
        result = self._receive_payload(candidate, request)
        ack = {"type": "ack", "protocol": PROTOCOL, "epoch": self.state["epoch"],
               "sequence": sequence, "request_sha256": request_sha,
               "status": "received", "authority": AUTHORITY, "duplicate": False,
               "result": result}
        candidate["last_sequence"] = sequence
        candidate["recent"].append({"sequence": sequence, "request_sha256": request_sha, "ack": ack})
        candidate["recent"] = candidate["recent"][-MAX_RECENT:]
        self._validate_state(candidate)
        atomic_json(self.path, candidate)
        self.state = candidate
        return copy.deepcopy(ack)

    def _receive_payload(self, candidate: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
        payload, kind = copy.deepcopy(request["payload"]), request["kind"]
        if kind == "echo":
            exact_fields(payload, {"text"}, "echo")
            if not isinstance(payload["text"], str) or len(payload["text"].encode("utf-8")) > 2048:
                raise ProtocolError("echo_budget")
            return {"text": payload["text"]}
        if kind == "intent_candidate":
            validate_intent(payload)
            if len(candidate["intents"]) >= MAX_INTENTS:
                raise ProtocolError("intent_budget")
            if any(item["payload"]["action_id"] == payload["action_id"] for item in candidate["intents"]):
                raise ProtocolError("intent_action_id_already_received")
            candidate["intents"].append({"sequence": request["sequence"], "authority": AUTHORITY,
                                         "status": "inspection_only", "payload": payload})
            return {"action_id": payload["action_id"], "execution": "not_available"}
        if kind == "batch_freeze":
            exact_fields(payload, set(), "batch_freeze")
            if len(candidate["batches"]) >= MAX_BATCHES:
                raise ProtocolError("batch_count_budget")
            frozen = {"schema": 1, "epoch": candidate["epoch"],
                      "batch_id": f"batch-{len(candidate['batches']) + 1}",
                      "members": ["HOST", "CLIENT"], "count": 0, "items": []}
            for intent in candidate["intents"]:
                if intent["sequence"] <= candidate["last_batched_sequence"]:
                    continue
                item = {"sender": "CLIENT", "sender_sequence": intent["sequence"],
                        "payload_sha256": digest(intent["payload"]),
                        "payload": copy.deepcopy(intent["payload"])}
                trial = dict(frozen, count=frozen["count"] + 1, items=frozen["items"] + [item])
                if trial["count"] > MAX_BATCH_ITEMS or len(canonical(trial)) > MAX_BATCH_BYTES:
                    break
                frozen = trial
            if not frozen["items"]:
                raise ProtocolError("no_unbatched_candidates_or_first_item_exceeds_batch_budget")
            batch = {"frozen": frozen, "batch_sha256": digest(frozen), "host_seen": True,
                     "client_seen": False, "state": "awaiting_client_receipt", "abort_reason": ""}
            validate_batch(batch, candidate["epoch"])
            candidate["batches"].append(batch)
            candidate["last_batched_sequence"] = frozen["items"][-1]["sender_sequence"]
            # The receipt describes this freeze operation permanently. Later
            # batch acknowledgements/aborts mutate current state, not an older
            # request's durable receipt or its retry response.
            return {"batch": copy.deepcopy(batch), "execution": "not_available"}
        if kind in {"batch_ack", "batch_abort"}:
            fields = {"batch_id", "batch_sha256", "count"} if kind == "batch_ack" else {"batch_id", "batch_sha256", "reason"}
            exact_fields(payload, fields, kind)
            batch = next((item for item in candidate["batches"] if item["frozen"]["batch_id"] == payload["batch_id"]), None)
            if batch is None:
                raise ProtocolError("unknown_batch")
            if payload["batch_sha256"] != batch["batch_sha256"]:
                raise ProtocolError("batch_ack_digest_conflict")
            if kind == "batch_ack":
                if type(payload["count"]) is not int or payload["count"] != batch["frozen"]["count"]:
                    raise ProtocolError("batch_ack_count_conflict")
                if batch["state"] == "aborted":
                    raise ProtocolError("batch_already_aborted")
                batch["client_seen"] = True
                batch["state"] = "ready_for_phase_proof"
            else:
                if not isinstance(payload["reason"], str) or not 0 < len(payload["reason"].encode("utf-8")) <= 192:
                    raise ProtocolError("batch_abort_reason_budget")
                if batch["state"] == "aborted" and batch["abort_reason"] != payload["reason"]:
                    raise ProtocolError("batch_abort_reason_conflict")
                batch["state"] = "aborted"
                batch["abort_reason"] = payload["reason"]
            return {"batch_id": batch["frozen"]["batch_id"], "batch_sha256": batch["batch_sha256"],
                    "state": batch["state"], "host_seen": batch["host_seen"], "client_seen": batch["client_seen"],
                    "abort_reason": batch["abort_reason"], "execution": "not_available"}
        exact_fields(payload, {"file_id", "name", "file_sha256", "total_bytes", "offset", "data_base64"}, "evidence")
        file_id = file_identifier(payload["file_id"])
        if not isinstance(payload["name"], str) or payload["name"] not in LOG_NAMES:
            raise ProtocolError("unsupported_evidence_name")
        if not isinstance(payload["file_sha256"], str) or not SHA256.fullmatch(payload["file_sha256"]):
            raise ProtocolError("invalid_evidence_digest")
        total = integer(payload["total_bytes"], 1, MAX_LOG_BYTES, "total_bytes")
        offset = integer(payload["offset"], 0, total - 1, "offset")
        if not isinstance(payload["data_base64"], str) or len(payload["data_base64"]) > MAX_CHUNK * 4 // 3:
            raise ProtocolError("evidence_chunk_budget")
        try:
            data = base64.b64decode(payload["data_base64"], validate=True)
        except (ValueError, UnicodeError) as error:
            raise ProtocolError("invalid_evidence_encoding") from error
        if not data or len(data) > MAX_CHUNK or offset + len(data) > total:
            raise ProtocolError("evidence_chunk_budget")
        files = candidate["evidence"]
        if file_id not in files:
            if offset != 0 or len(files) >= MAX_LOG_FILES:
                raise ProtocolError("evidence_file_budget_or_missing_prefix")
            files[file_id] = {"name": payload["name"], "file_sha256": payload["file_sha256"],
                              "total_bytes": total, "received_bytes": 0, "parts": []}
        file = files[file_id]
        if any(file[field] != payload[field] for field in ("name", "file_sha256", "total_bytes")):
            raise ProtocolError("evidence_file_identity_conflict")
        if file["received_bytes"] != offset:
            raise ProtocolError("evidence_offset_conflict")
        if candidate["evidence_bytes"] + len(data) > MAX_EVIDENCE_BYTES:
            raise ProtocolError("evidence_total_budget")
        # Verify the final assembled digest BEFORE writing a new blob. Otherwise
        # invalid retries could accumulate unreferenced files outside the budget.
        if offset + len(data) == total:
            whole = hashlib.sha256()
            for part in file["parts"]:
                previous = self.directory / "evidence-blobs" / f"{part['sha256']}.bin"
                if previous.stat().st_size != part["bytes"]:
                    raise ProtocolError("evidence_blob_size_mismatch")
                previous_data = previous.read_bytes()
                if hashlib.sha256(previous_data).hexdigest() != part["sha256"]:
                    raise ProtocolError("evidence_blob_digest_mismatch")
                whole.update(previous_data)
            whole.update(data)
            if whole.hexdigest() != file["file_sha256"]:
                raise ProtocolError("evidence_file_digest_mismatch")
        sha = hashlib.sha256(data).hexdigest()
        blob_path = self.directory / "evidence-blobs" / f"{sha}.bin"
        if blob_path.exists():
            if blob_path.read_bytes() != data:
                raise ProtocolError("stored_evidence_corrupt")
        else:
            atomic_bytes(blob_path, data, replace=False)
        file["parts"].append({"sha256": sha, "bytes": len(data)})
        file["received_bytes"] += len(data)
        candidate["evidence_bytes"] += len(data)
        if file["received_bytes"] == total:
            self.evidence_content(file)  # A false declared whole-file digest cannot be ACKed complete.
        return {"file_id": file_id, "received_bytes": file["received_bytes"],
                "total_bytes": total, "complete": file["received_bytes"] == total}

    def evidence_content(self, file: dict[str, Any]) -> bytes:
        if file["received_bytes"] != file["total_bytes"]:
            raise ProtocolError("evidence_incomplete")
        content = bytearray()
        for part in file["parts"]:
            blob = self.directory / "evidence-blobs" / f"{part['sha256']}.bin"
            if blob.stat().st_size != part["bytes"]:
                raise ProtocolError("evidence_blob_size_mismatch")
            data = blob.read_bytes()
            if hashlib.sha256(data).hexdigest() != part["sha256"]:
                raise ProtocolError("evidence_blob_digest_mismatch")
            content.extend(data)
        if hashlib.sha256(content).hexdigest() != file["file_sha256"]:
            raise ProtocolError("evidence_file_digest_mismatch")
        return bytes(content)


class ClientStore:
    """Pending request survives loss of ACK; retries use the exact same bytes/ID."""

    def __init__(self, directory: Path, epoch: str, identity_sha256: str):
        self.path = directory / "client-state.json"
        identifier(epoch, "epoch")
        if not isinstance(identity_sha256, str) or not SHA256.fullmatch(identity_sha256):
            raise ProtocolError("invalid_identity_digest")
        if self.path.exists():
            self.state = load_json(self.path)
            exact_fields(self.state, {"schema", "protocol", "authority", "epoch", "identity_sha256", "last_sequence", "pending", "uploads", "batches", "intent_ids"}, "client_state")
            if type(self.state["schema"]) is not int or self.state["schema"] != STATE_SCHEMA or type(self.state["protocol"]) is not int or self.state["protocol"] != PROTOCOL:
                raise ProtocolError("unsupported_state_schema")
            if self.state["epoch"] != epoch or self.state["identity_sha256"] != identity_sha256 or self.state["authority"] != AUTHORITY:
                raise ProtocolError("client_epoch_or_identity_mismatch_use_new_directory")
            last = integer(self.state["last_sequence"], 0, MAX_SEQUENCE, "last_sequence")
            self._validate_uploads(self.state["uploads"])
            self._validate_batches(self.state["batches"], epoch)
            ids = self.state["intent_ids"]
            if not isinstance(ids, list) or len(ids) > MAX_INTENTS or any(not isinstance(item, str) or not IDENTIFIER.fullmatch(item) for item in ids) or len(set(ids)) != len(ids):
                raise ProtocolError("invalid_client_intent_ids")
            if self.state["pending"] is not None:
                pending = validate_request(self.state["pending"], epoch)
                if pending["sequence"] != last + 1:
                    raise ProtocolError("corrupt_pending_sequence")
        else:
            self.state = {"schema": STATE_SCHEMA, "protocol": PROTOCOL, "authority": AUTHORITY,
                          "epoch": epoch, "identity_sha256": identity_sha256,
                          "last_sequence": 0, "pending": None, "uploads": {}, "batches": {}, "intent_ids": []}
            atomic_json(self.path, self.state, replace=False)

    @staticmethod
    def _validate_uploads(uploads: Any) -> None:
        if not isinstance(uploads, dict) or len(uploads) > MAX_LOG_FILES:
            raise ProtocolError("client_upload_budget")
        for key, item in uploads.items():
            file_identifier(key)
            exact_fields(item, {"name", "file_sha256", "total_bytes", "received_bytes"}, "client_upload")
            if not isinstance(item["name"], str) or item["name"] not in LOG_NAMES or not isinstance(item["file_sha256"], str) or not SHA256.fullmatch(item["file_sha256"]):
                raise ProtocolError("invalid_client_upload_identity")
            maximum = integer(item["total_bytes"], 1, MAX_LOG_BYTES, "total_bytes")
            integer(item["received_bytes"], 1, maximum, "received_bytes")

    @staticmethod
    def _validate_batches(batches: Any, epoch: str) -> None:
        if not isinstance(batches, dict) or len(batches) > MAX_BATCHES:
            raise ProtocolError("client_batch_count_budget")
        for batch_id, batch in batches.items():
            validate_batch(batch, epoch)
            if batch["frozen"]["batch_id"] != batch_id:
                raise ProtocolError("client_batch_id_conflict")

    def prepare(self, kind: str, payload: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(kind, str) or not isinstance(payload, dict):
            raise ProtocolError("invalid_request_kind_or_payload_type")
        _validate_json(payload)
        pending = self.state["pending"]
        if pending is not None:
            if pending["kind"] != kind or pending["payload"] != payload:
                raise ProtocolError("pending_request_exists_resume_it_first")
            return copy.deepcopy(pending)
        if self.state["last_sequence"] >= MAX_SEQUENCE:
            raise ProtocolError("sequence_exhausted_use_new_epoch")
        if kind == "intent_candidate":
            validate_intent(payload)
            if len(self.state["intent_ids"]) >= MAX_INTENTS or payload["action_id"] in self.state["intent_ids"]:
                raise ProtocolError("client_intent_budget_or_duplicate_action_id")
        elif kind == "echo":
            exact_fields(payload, {"text"}, "echo")
            if not isinstance(payload["text"], str) or len(payload["text"].encode("utf-8")) > 2048:
                raise ProtocolError("echo_budget")
        elif kind == "batch_freeze":
            exact_fields(payload, set(), "batch_freeze")
            if len(self.state["batches"]) >= MAX_BATCHES:
                raise ProtocolError("client_batch_count_budget")
            if sum(item["frozen"]["count"] for item in self.state["batches"].values()) >= len(self.state["intent_ids"]):
                raise ProtocolError("no_unbatched_client_candidates")
        elif kind in {"batch_ack", "batch_abort"}:
            fields = {"batch_id", "batch_sha256", "count"} if kind == "batch_ack" else {"batch_id", "batch_sha256", "reason"}
            exact_fields(payload, fields, kind)
            identifier(payload["batch_id"], "batch_id")
            batch = self.state["batches"].get(payload.get("batch_id"))
            if batch is None or batch["batch_sha256"] != payload.get("batch_sha256"):
                raise ProtocolError("batch_not_durably_observed_by_client")
            if kind == "batch_ack" and (batch["state"] == "aborted" or type(payload["count"]) is not int or payload["count"] != batch["frozen"]["count"]):
                raise ProtocolError("batch_ack_state_or_count_conflict")
            if kind == "batch_abort":
                if not isinstance(payload["reason"], str) or not 0 < len(payload["reason"].encode("utf-8")) <= 192:
                    raise ProtocolError("batch_abort_reason_budget")
                if batch["state"] == "aborted" and batch["abort_reason"] != payload["reason"]:
                    raise ProtocolError("batch_abort_reason_conflict")
        if kind == "evidence_part":
            file_id = file_identifier(payload.get("file_id"))
            upload = self.state["uploads"].get(file_id)
            if upload is not None:
                if any(payload.get(field) != upload[field] for field in ("name", "file_sha256", "total_bytes")) or payload.get("offset") != upload["received_bytes"]:
                    raise ProtocolError("client_upload_identity_or_offset_conflict")
            elif len(self.state["uploads"]) >= MAX_LOG_FILES or payload.get("offset") != 0:
                raise ProtocolError("client_upload_budget_or_missing_prefix")
        request = make_request(self.state["epoch"], self.state["last_sequence"] + 1, kind, payload)
        # Validate wire budget before saving an unsendable pending operation.
        encode_frame(request, b"\0" * 32)
        candidate = dict(self.state, pending=request)
        atomic_json(self.path, candidate)
        self.state = candidate
        return copy.deepcopy(request)

    def acknowledge(self, ack: Any) -> None:
        pending = self.state["pending"]
        if pending is None:
            raise ProtocolError("no_pending_request")
        exact_fields(ack, {"type", "protocol", "epoch", "sequence", "request_sha256", "status", "authority", "duplicate", "result"}, "ack")
        if (ack["type"] != "ack" or type(ack["protocol"]) is not int or ack["protocol"] != PROTOCOL or ack["epoch"] != self.state["epoch"]
                or type(ack["sequence"]) is not int or ack["sequence"] != pending["sequence"] or ack["request_sha256"] != digest(pending)
                or ack["status"] != "received" or ack["authority"] != AUTHORITY
                or type(ack["duplicate"]) is not bool or not isinstance(ack["result"], dict)):
            raise ProtocolError("ack_does_not_match_pending_request")
        candidate = copy.deepcopy(self.state)
        candidate.update(last_sequence=pending["sequence"], pending=None)
        payload = pending["payload"]
        if pending["kind"] == "evidence_part":
            result = ack["result"]
            exact_fields(result, {"file_id", "received_bytes", "total_bytes", "complete"}, "evidence_ack")
            integer(result["received_bytes"], 1, MAX_LOG_BYTES, "evidence_ack_received_bytes")
            integer(result["total_bytes"], 1, MAX_LOG_BYTES, "evidence_ack_total_bytes")
            if type(result["complete"]) is not bool:
                raise ProtocolError("invalid_evidence_ack_complete")
            received = payload["offset"] + len(base64.b64decode(payload["data_base64"], validate=True))
            if result != {"file_id": payload["file_id"], "received_bytes": received,
                          "total_bytes": payload["total_bytes"], "complete": received == payload["total_bytes"]}:
                raise ProtocolError("evidence_ack_size_mismatch")
            candidate["uploads"][payload["file_id"]] = {
                "name": payload["name"], "file_sha256": payload["file_sha256"],
                "total_bytes": payload["total_bytes"], "received_bytes": received}
            self._validate_uploads(candidate["uploads"])
        elif pending["kind"] == "echo" and ack["result"] != {"text": payload["text"]}:
            raise ProtocolError("echo_result_mismatch")
        elif pending["kind"] == "intent_candidate":
            if ack["result"] != {"action_id": payload["action_id"], "execution": "not_available"}:
                raise ProtocolError("intent_receipt_mismatch")
            candidate["intent_ids"].append(payload["action_id"])
        elif pending["kind"] == "batch_freeze":
            exact_fields(ack["result"], {"batch", "execution"}, "batch_freeze_ack")
            batch = copy.deepcopy(ack["result"]["batch"])
            validate_batch(batch, self.state["epoch"])
            if ack["result"]["execution"] != "not_available" or batch["state"] != "awaiting_client_receipt":
                raise ProtocolError("invalid_batch_freeze_state")
            if batch["frozen"]["batch_id"] in candidate["batches"]:
                raise ProtocolError("batch_already_observed_under_another_request")
            candidate["batches"][batch["frozen"]["batch_id"]] = batch
        elif pending["kind"] in {"batch_ack", "batch_abort"}:
            result = ack["result"]
            exact_fields(result, {"batch_id", "batch_sha256", "state", "host_seen", "client_seen", "abort_reason", "execution"}, "batch_receipt")
            if result["batch_id"] != payload["batch_id"] or result["batch_sha256"] != payload["batch_sha256"] or result["execution"] != "not_available":
                raise ProtocolError("batch_receipt_conflict")
            expected_state = "ready_for_phase_proof" if pending["kind"] == "batch_ack" else "aborted"
            if result["state"] != expected_state:
                raise ProtocolError("unexpected_batch_receipt_state")
            batch = candidate["batches"][payload["batch_id"]]
            for field in ("state", "host_seen", "client_seen", "abort_reason"):
                batch[field] = result[field]
            if pending["kind"] == "batch_abort" and batch["abort_reason"] != payload["reason"]:
                raise ProtocolError("batch_abort_receipt_reason_conflict")
        self._validate_batches(candidate["batches"], self.state["epoch"])
        atomic_json(self.path, candidate)
        self.state = candidate
