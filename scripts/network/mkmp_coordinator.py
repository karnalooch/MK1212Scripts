#!/usr/bin/env python3
"""HOST/CLIENT coordinator for MK1212 N4 evidence and receipt experiments.

Python 3.10+, standard library only. See docs/runtime/MP_HOST_COORDINATOR.md.
No command in this program executes, resumes, or repairs Attila gameplay.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import sys
import time
from typing import Any

from mkmp_preflight import load_preflight, write_preflight
from mkmp_transport import (AUTHORITY, LOG_NAMES, MAX_CHUNK, MAX_LOG_BYTES, PROTOCOL,
                            ClientStore, DirectoryLock, HostStore, ProtocolError,
                            atomic_bytes, atomic_json, exact_fields, file_identifier, identifier,
                            integer, load_json, read_key, receive_frame, send_frame)


class NetworkFailure(Exception):
    pass


def status(event: str, **values: Any) -> None:
    print(json.dumps({"event": event, "authority": AUTHORITY, **values},
                     sort_keys=True, ensure_ascii=True), flush=True)


def serve_connection(stream: socket.socket, key: bytes, store: HostStore) -> dict[str, Any]:
    """One authenticated handshake and one request. Runs no game callbacks."""
    challenge = secrets.token_hex(24)
    send_frame(stream, {"type": "challenge", "protocol": PROTOCOL,
                        "challenge": challenge, "epoch": store.state["epoch"],
                        "identity_sha256": store.state["identity_sha256"],
                        "authority": AUTHORITY}, key)
    hello = receive_frame(stream, key)
    send_frame(stream, store.hello(hello, challenge), key)
    ack = store.receive(receive_frame(stream, key))
    send_frame(stream, ack, key)
    return ack


def _reject(response: dict[str, Any]) -> None:
    if response.get("type") == "reject":
        reason = response.get("reason", "peer_rejected_request")
        if not isinstance(reason, str) or len(reason) > 192:
            reason = "peer_rejected_request"
        raise ProtocolError(reason)


def request_connection(stream: socket.socket, key: bytes, store: ClientStore,
                       request: dict[str, Any]) -> dict[str, Any]:
    challenge = receive_frame(stream, key)
    exact_fields(challenge, {"type", "protocol", "challenge", "epoch", "identity_sha256", "authority"}, "challenge")
    if challenge["type"] != "challenge" or type(challenge["protocol"]) is not int or challenge["protocol"] != PROTOCOL or challenge["authority"] != AUTHORITY:
        raise ProtocolError("unsupported_host_protocol")
    identifier(challenge["challenge"], "challenge")
    if challenge["epoch"] != store.state["epoch"]:
        raise ProtocolError("stale_or_unknown_epoch")
    if challenge["identity_sha256"] != store.state["identity_sha256"]:
        raise ProtocolError("preflight_identity_mismatch")
    hello = {"type": "hello", "protocol": PROTOCOL, "epoch": store.state["epoch"],
             "actor": "CLIENT", "challenge": challenge["challenge"],
             "identity_sha256": store.state["identity_sha256"], "authority": AUTHORITY}
    send_frame(stream, hello, key)
    ready = receive_frame(stream, key)
    _reject(ready)
    exact_fields(ready, {"type", "protocol", "epoch", "identity_sha256", "authority", "last_sequence"}, "ready")
    if ready["type"] != "ready" or type(ready["protocol"]) is not int or ready["protocol"] != PROTOCOL or ready["epoch"] != store.state["epoch"] or ready["identity_sha256"] != store.state["identity_sha256"] or ready["authority"] != AUTHORITY:
        raise ProtocolError("invalid_host_ready")
    last = integer(ready["last_sequence"], 0, 16_777_215, "host_last_sequence")
    if last < store.state["last_sequence"]:
        raise ProtocolError("host_receipt_ledger_behind_client")
    if last > store.state["last_sequence"] + 1:
        raise ProtocolError("client_ledger_behind_multiple_receipts")
    send_frame(stream, request, key)
    ack = receive_frame(stream, key)
    _reject(ack)
    return ack


def _tls_server(args: argparse.Namespace) -> ssl.SSLContext | None:
    if args.trusted_lan:
        if args.cert or args.cert_key:
            raise ProtocolError("select_tls_or_trusted_lan")
        return None
    if not args.cert or not args.cert_key:
        raise ProtocolError("tls_requires_certificate_and_private_key_or_explicit_trusted_lan")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.cert_key)
    return context


def _tls_client(args: argparse.Namespace) -> ssl.SSLContext | None:
    if args.trusted_lan:
        if args.ca or args.server_name:
            raise ProtocolError("select_tls_or_trusted_lan")
        return None
    if not args.ca or not args.server_name:
        raise ProtocolError("tls_requires_ca_and_server_name_or_explicit_trusted_lan")
    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=str(args.ca))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


def run_host(args: argparse.Namespace) -> None:
    context = _tls_server(args)
    key = read_key(args.key_file)
    with DirectoryLock(args.state_dir):
        store = HostStore(args.state_dir)
        identity = load_preflight(args.state_dir / "host-preflight.json", "HOST")
        if identity["identity_sha256"] != store.state["identity_sha256"]:
            raise ProtocolError("host_preflight_state_mismatch")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind((args.bind, args.port))
            server.listen(2)
            server.settimeout(1)
            status("host_listening", bind=args.bind, port=server.getsockname()[1],
                   epoch=store.state["epoch"], tls=context is not None,
                   identity_sha256=store.state["identity_sha256"], max_connections=args.max_connections)
            count = 0
            while count < args.max_connections:
                try:
                    connection, address = server.accept()
                except socket.timeout:
                    continue
                count += 1
                connection.settimeout(args.timeout)
                try:
                    if args.client_address and address[0] != args.client_address:
                        status("connection_rejected", reason="client_address_mismatch")
                        continue
                    if context is not None:
                        connection = context.wrap_socket(connection, server_side=True)
                    ack = serve_connection(connection, key, store)
                    status("receipt", sequence=ack["sequence"], duplicate=ack["duplicate"], status=ack["status"])
                except ProtocolError as error:
                    reason = str(error)
                    try:
                        send_frame(connection, {"type": "reject", "protocol": PROTOCOL,
                                                "reason": reason}, key)
                    except (OSError, ConnectionError):
                        pass
                    status("request_rejected", reason=reason)
                except (ConnectionError, socket.timeout, ssl.SSLError):
                    status("connection_interrupted", outcome="receipt_may_already_exist_retry_same_id")
                finally:
                    connection.close()
            status("host_connection_budget_reached", connections=count)


def transmit(args: argparse.Namespace, key: bytes, store: ClientStore,
             request: dict[str, Any], context: ssl.SSLContext | None) -> dict[str, Any]:
    for attempt in range(1, args.retries + 1):
        connection = None
        try:
            connection = socket.create_connection((args.host, args.port), timeout=args.timeout)
            if context is not None:
                connection = context.wrap_socket(connection, server_hostname=args.server_name)
            connection.settimeout(args.timeout)
            ack = request_connection(connection, key, store, request)
        except (ConnectionError, socket.timeout, ssl.SSLError, OSError) as error:
            # Retry only this unchanged receipt request. There is no model
            # execution, unknown engine result, or application retry here.
            if attempt == args.retries:
                raise NetworkFailure("connection_failed_pending_request_preserved_resume_same_id") from error
            time.sleep(min(attempt, 2))
            continue
        finally:
            if connection is not None:
                connection.close()
        # A local durable-state failure is an IO failure, not a network retry.
        store.acknowledge(ack)
        return ack
    raise NetworkFailure("connection_failed")


def upload_log(args: argparse.Namespace, key: bytes, store: ClientStore,
               context: ssl.SSLContext | None) -> None:
    path = args.log
    if path.name not in LOG_NAMES:
        raise ProtocolError("evidence_file_must_be_MK1212_mp_debug.log_or_twdll.log")
    before = path.stat()
    if not 0 < before.st_size <= MAX_LOG_BYTES:
        raise ProtocolError("log_empty_or_over_16_MiB_budget_no_silent_truncation")
    content = path.read_bytes()
    after = path.stat()
    if before.st_size != after.st_size or before.st_mtime_ns != after.st_mtime_ns:
        raise ProtocolError("log_changed_copy_after_game_exit_then_collect")
    sha = hashlib.sha256(content).hexdigest()
    file_id = file_identifier(args.file_id or f"client_{path.stem.lower()}_{sha[:24]}")
    existing = store.state["uploads"].get(file_id)
    offset = existing["received_bytes"] if existing else 0
    if existing and (existing["file_sha256"] != sha or existing["total_bytes"] != len(content) or existing["name"] != path.name):
        raise ProtocolError("evidence_file_changed_use_new_file_id_or_epoch")
    while offset < len(content):
        part = content[offset:offset + MAX_CHUNK]
        payload = {"file_id": file_id, "name": path.name, "file_sha256": sha,
                   "total_bytes": len(content), "offset": offset,
                   "data_base64": base64.b64encode(part).decode("ascii")}
        request = store.prepare("evidence_part", payload)
        transmit(args, key, store, request, context)
        offset = store.state["uploads"][file_id]["received_bytes"]
    status("evidence_received", file_id=file_id, name=path.name, bytes=len(content),
           sha256=sha, meaning="diagnostic_file_received_not_compared_or_applied")


def run_client(args: argparse.Namespace) -> None:
    context = _tls_client(args)
    key = read_key(args.key_file)
    identity = load_preflight(args.identity, "CLIENT")
    with DirectoryLock(args.state_dir):
        store = ClientStore(args.state_dir, args.epoch, identity["identity_sha256"])
        if args.operation == "collect":
            upload_log(args, key, store, context)
            return
        if args.operation == "batch-buffer":
            request = store.prepare("batch_freeze", {})
            frozen_ack = transmit(args, key, store, request, context)
            batch = frozen_ack["result"]["batch"]
            request = store.prepare("batch_ack", {"batch_id": batch["frozen"]["batch_id"],
                "batch_sha256": batch["batch_sha256"], "count": batch["frozen"]["count"]})
            ack = transmit(args, key, store, request, context)
            status("candidate_batch_buffered", **ack["result"])
            return
        if args.operation == "resume":
            request = store.state["pending"]
            if request is None:
                status("nothing_pending", last_sequence=store.state["last_sequence"])
                return
        elif args.operation == "echo":
            if len(args.text.encode("utf-8")) > 2048:
                raise ProtocolError("echo_budget")
            request = store.prepare("echo", {"text": args.text})
        elif args.operation == "batch-freeze":
            request = store.prepare("batch_freeze", {})
        elif args.operation in {"batch-ack", "batch-abort"}:
            batch = store.state["batches"].get(args.batch_id)
            if batch is None:
                raise ProtocolError("batch_not_durably_observed_by_client")
            payload = {"batch_id": args.batch_id, "batch_sha256": batch["batch_sha256"]}
            if args.operation == "batch-ack":
                payload["count"] = batch["frozen"]["count"]
            else:
                if not 0 < len(args.reason.encode("utf-8")) <= 192:
                    raise ProtocolError("batch_abort_reason_budget")
                payload["reason"] = args.reason
            request = store.prepare(args.operation.replace("-", "_"), payload)
        else:
            payload = load_json(args.intent)
            exact_fields(payload, {"kind", "actor_faction", "action_id", "phase", "data"}, "intent")
            for field in ("kind", "actor_faction", "action_id", "phase"):
                identifier(payload[field], field)
            if not isinstance(payload["data"], dict):
                raise ProtocolError("intent_data_must_be_object")
            request = store.prepare("intent_candidate", payload)
        ack = transmit(args, key, store, request, context)
        status("client_received_ack", sequence=ack["sequence"], duplicate=ack["duplicate"],
               result=ack["result"], meaning="received_not_applied")


def export_evidence(args: argparse.Namespace) -> None:
    # Lock excludes a concurrent writer: exported bytes correspond to one
    # validated durable ledger snapshot, without partially written records.
    with DirectoryLock(args.state_dir):
        store = HostStore(args.state_dir)
        if args.output_dir.exists() and any(args.output_dir.iterdir()):
            raise ProtocolError("export_destination_must_be_empty")
        args.output_dir.mkdir(parents=True, exist_ok=True)
        files: list[dict[str, Any]] = []
        for file_id, entry in sorted(store.state["evidence"].items()):
            if entry["received_bytes"] != entry["total_bytes"]:
                raise ProtocolError("evidence_incomplete_finish_upload_before_export")
            data = store.evidence_content(entry)
            target = args.output_dir / file_id / entry["name"]
            atomic_bytes(target, data, replace=False)
            files.append({"file_id": file_id, "relative_path": f"{file_id}/{entry['name']}",
                          "bytes": len(data), "sha256": entry["file_sha256"], "role": "CLIENT"})
        if args.host_log:
            path = args.host_log
            before = path.stat()
            if path.name not in LOG_NAMES or not 0 < before.st_size <= MAX_LOG_BYTES:
                raise ProtocolError("invalid_host_evidence_log")
            data = path.read_bytes()
            after = path.stat()
            if before.st_size != after.st_size or before.st_mtime_ns != after.st_mtime_ns:
                raise ProtocolError("host_log_changed_copy_after_game_exit")
            target = args.output_dir / "HOST" / path.name
            atomic_bytes(target, data, replace=False)
            files.append({"relative_path": f"HOST/{path.name}", "bytes": len(data),
                          "sha256": hashlib.sha256(data).hexdigest(), "role": "HOST"})
        result = {"schema": 1, "authority": AUTHORITY, "epoch": store.state["epoch"],
                  "identity_sha256": store.state["identity_sha256"], "files": files,
                  "both_roles_present": {item["role"] for item in files} == {"HOST", "CLIENT"},
                  "logs_compared": False, "attila_runtime_synchronization_proven": False}
        atomic_json(args.output_dir / "evidence-manifest.json", result, replace=False)
        atomic_json(args.output_dir / "intent-candidates.json", {
            "schema": 1, "authority": AUTHORITY, "epoch": store.state["epoch"],
            "execution": "not_available", "records": store.state["intents"]}, replace=False)
        atomic_json(args.output_dir / "candidate-batches.json", {
            "schema": 1, "authority": AUTHORITY, "epoch": store.state["epoch"],
            "execution": "not_available", "records": store.state["batches"]}, replace=False)
        atomic_json(args.output_dir / "host-preflight.json",
                    load_preflight(args.state_dir / "host-preflight.json", "HOST"), replace=False)
        status("evidence_exported", directory=str(args.output_dir), files=len(files),
               both_roles_present=result["both_roles_present"], logs_compared=False)


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preflight = commands.add_parser("preflight", help="hash actual game/pack/mod files and declared launch/save provenance")
    preflight.add_argument("--game-dir", type=Path, required=True)
    preflight.add_argument("--retail-dll", type=Path)
    preflight.add_argument("--manifest", type=Path, required=True)
    preflight.add_argument("--pack", type=Path, required=True)
    preflight.add_argument("--load-order", type=Path, required=True)
    preflight.add_argument("--game-build", required=True)
    preflight.add_argument("--steam-branch", required=True)
    preflight.add_argument("--role", choices=["HOST", "CLIENT"], required=True)
    save = preflight.add_mutually_exclusive_group(required=True)
    save.add_argument("--save", type=Path)
    save.add_argument("--new-campaign-key")
    config = preflight.add_mutually_exclusive_group(required=True)
    config.add_argument("--config", type=Path)
    config.add_argument("--config-absent", action="store_true")
    native = preflight.add_mutually_exclusive_group(required=True)
    native.add_argument("--native-dll", type=Path)
    native.add_argument("--native-absent", action="store_true")
    preflight.add_argument("--output", type=Path, required=True)

    init = commands.add_parser("init-host", help="create a NEW epoch/state/key directory; never overwrites an old session")
    init.add_argument("--state-dir", type=Path, required=True)
    init.add_argument("--identity", type=Path, required=True)
    init.add_argument("--epoch", required=True)

    host = commands.add_parser("host", help="listen for authenticated evidence/echo requests")
    host.add_argument("--state-dir", type=Path, required=True)
    host.add_argument("--key-file", type=Path, required=True)
    host.add_argument("--bind", default="127.0.0.1")
    host.add_argument("--port", type=int, default=12124)
    host.add_argument("--client-address")
    host.add_argument("--max-connections", type=int, default=4096)
    host.add_argument("--timeout", type=int, default=10)
    host.add_argument("--trusted-lan", action="store_true", help="explicitly allow authenticated plaintext on a trusted LAN/VPN")
    host.add_argument("--cert", type=Path)
    host.add_argument("--cert-key", type=Path)

    client = commands.add_parser("client", help="send evidence or one receipt-only request")
    client.add_argument("--state-dir", type=Path, required=True)
    client.add_argument("--key-file", type=Path, required=True)
    client.add_argument("--identity", type=Path, required=True)
    client.add_argument("--epoch", required=True)
    client.add_argument("--host", required=True)
    client.add_argument("--port", type=int, default=12124)
    client.add_argument("--timeout", type=int, default=10)
    client.add_argument("--retries", type=int, default=3)
    client.add_argument("--trusted-lan", action="store_true")
    client.add_argument("--ca", type=Path)
    client.add_argument("--server-name")
    operations = client.add_subparsers(dest="operation", required=True)
    echo = operations.add_parser("echo")
    echo.add_argument("--text", default="MK1212 N4 echo")
    collect = operations.add_parser("collect")
    collect.add_argument("--log", type=Path, required=True)
    collect.add_argument("--file-id")
    operations.add_parser("resume", help="retry only the unchanged durable pending request")
    intent = operations.add_parser("intent-candidate", help="record a candidate for inspection; never engine execution")
    intent.add_argument("--intent", type=Path, required=True)
    operations.add_parser("batch-freeze", help="ask HOST to freeze the accepted candidate list and its digest")
    operations.add_parser("batch-buffer", help="freeze then acknowledge the exact batch; never execute it")
    batch_ack = operations.add_parser("batch-ack", help="acknowledge a previously durably observed batch")
    batch_ack.add_argument("--batch-id", required=True)
    batch_abort = operations.add_parser("batch-abort", help="explicitly abort a frozen batch while retaining its evidence")
    batch_abort.add_argument("--batch-id", required=True)
    batch_abort.add_argument("--reason", required=True)

    export = commands.add_parser("export", help="after stopping HOST, verify and export received evidence plus the HOST log")
    export.add_argument("--state-dir", type=Path, required=True)
    export.add_argument("--output-dir", type=Path, required=True)
    export.add_argument("--host-log", type=Path)
    args = parser.parse_args(argv)
    if hasattr(args, "port") and not 1 <= args.port <= 65535:
        parser.error("port must be 1..65535")
    if hasattr(args, "timeout") and not 1 <= args.timeout <= 30:
        parser.error("timeout must be 1..30 seconds")
    if hasattr(args, "retries") and not 1 <= args.retries <= 5:
        parser.error("retries must be 1..5")
    if hasattr(args, "max_connections") and not 1 <= args.max_connections <= 10_000:
        parser.error("max-connections must be 1..10000")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "preflight":
            result = write_preflight(args.output, game_directory=args.game_dir,
                manifest_path=args.manifest, pack_path=args.pack, load_order_path=args.load_order,
                game_build=args.game_build, steam_branch=args.steam_branch,
                save_path=args.save, new_campaign_key=args.new_campaign_key,
                config_path=args.config, config_absent=args.config_absent,
                native_path=args.native_dll, native_absent=args.native_absent,
                role=args.role, dll_path=args.retail_dll)
            status("preflight_written", path=str(args.output), identity_sha256=result["identity_sha256"],
                   role=args.role, source_commit_sha=result["compatibility"]["source_commit_sha"])
        elif args.command == "init-host":
            identity = load_preflight(args.identity, "HOST")
            identifier(args.epoch, "epoch")
            with DirectoryLock(args.state_dir):
                if any(path.name != "owner.lock" for path in args.state_dir.iterdir()):
                    raise ProtocolError("init_requires_new_empty_state_directory")
                atomic_json(args.state_dir / "host-preflight.json", identity, replace=False)
                atomic_bytes(args.state_dir / "session-key.txt", (secrets.token_hex(32) + "\n").encode("ascii"), replace=False)
                HostStore.create(args.state_dir, args.epoch, identity["identity_sha256"])
            status("host_initialized", epoch=args.epoch, state_directory=str(args.state_dir),
                   key_file=str(args.state_dir / "session-key.txt"),
                   next="copy_key_privately_to_CLIENT_then_start_host")
        elif args.command == "host":
            run_host(args)
        elif args.command == "client":
            run_client(args)
        else:
            export_evidence(args)
        return 0
    except ProtocolError as error:
        print(json.dumps({"status": "REJECTED", "reason": str(error), "authority": AUTHORITY}), file=sys.stderr)
        return 6 if "preflight" in str(error) and "mismatch" in str(error) else 3
    except NetworkFailure as error:
        print(json.dumps({"status": "PENDING", "reason": str(error), "authority": AUTHORITY}), file=sys.stderr)
        return 5
    except OSError as error:
        print(json.dumps({"status": "IO_FAILURE", "reason": error.strerror or type(error).__name__, "authority": AUTHORITY}), file=sys.stderr)
        return 4
    except KeyboardInterrupt:
        status("stopped", reason="user_interrupt", pending_requests="preserved")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
