"""Consolidated N4 receipt/provenance fault checks; not Attila runtime proof."""
from __future__ import annotations

import base64
import copy
import hashlib
import json
from pathlib import Path
import socket
import struct
import sys
import tempfile
import threading
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/network"))
sys.path.insert(0, str(ROOT / "scripts/ci"))

import mkmp_transport as transport
from mkmp_coordinator import request_connection, serve_connection
from mkmp_preflight import build_preflight, load_preflight
from lua_test_runtime import run_lua_fixture


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mkmp-n4-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.host = transport.HostStore.create(self.directory / "host", "test-epoch-1", "a" * 64)
        self.client = transport.ClientStore(self.directory / "client", "test-epoch-1", "a" * 64)
        self.key = b"k" * 32

    def echo(self, sequence=1, text="hello", epoch="test-epoch-1"):
        return transport.make_request(epoch, sequence, "echo", {"text": text})

    def exchange(self, request, *, lose_ack=False):
        errors = []
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(3)

        class Stream:
            def __init__(self, raw):
                self.raw = raw

            def recv(self, length):
                return self.raw.recv(length)

            def sendall(self, data):
                if lose_ack and b'"type":"ack"' in data:
                    self.raw.shutdown(socket.SHUT_RDWR)
                    return
                self.raw.sendall(data)

        def server():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(3)
                    serve_connection(Stream(connection), self.key, self.host)
            except BaseException as error:
                errors.append(error)

        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        try:
            with socket.create_connection(listener.getsockname(), timeout=3) as connection:
                result = request_connection(connection, self.key, self.client, request)
        finally:
            thread.join(4)
            self.assertFalse(thread.is_alive(), "loopback worker did not terminate")
            if errors:
                raise errors[0]
        return result

    def test_actual_loopback_lost_ack_reconnect_keeps_id_and_persisted_receipt(self):
        pending = self.client.prepare("echo", {"text": "receipt only"})
        with self.assertRaises(ConnectionError):
            self.exchange(pending, lose_ack=True)
        self.assertEqual(self.host.state["last_sequence"], 1)
        self.host = transport.HostStore(self.directory / "host")
        self.client = transport.ClientStore(self.directory / "client", "test-epoch-1", "a" * 64)
        self.assertEqual(pending, self.client.state["pending"])
        ack = self.exchange(self.client.state["pending"])
        self.client.acknowledge(ack)
        self.assertTrue(ack["duplicate"])
        self.assertEqual(ack["authority"], "evidence_only")
        self.assertEqual(ack["status"], "received")
        self.assertEqual(len(self.host.state["recent"]), 1)
        self.assertIsNone(self.client.state["pending"])

    def test_gap_conflict_stale_epoch_and_authority_are_rejected_without_advancing(self):
        self.host.receive(self.echo())
        before = self.host.path.read_bytes()
        for request, reason in ((self.echo(3), "sequence_gap"),
                                (self.echo(1, "changed"), "sequence_payload_conflict"),
                                (self.echo(2, epoch="old-epoch"), "stale_or_unknown_epoch")):
            with self.subTest(reason=reason), self.assertRaisesRegex(transport.ProtocolError, reason):
                self.host.receive(request)
            self.assertEqual(self.host.path.read_bytes(), before)
        hello = {"type": "hello", "protocol": 1, "epoch": "test-epoch-1", "actor": "CLIENT",
                 "challenge": "nonce", "identity_sha256": "a" * 64, "authority": "apply"}
        with self.assertRaisesRegex(transport.ProtocolError, "unsupported_authority"):
            self.host.hello(hello, "nonce")
        hello.update(authority="evidence_only", identity_sha256="b" * 64)
        with self.assertRaisesRegex(transport.ProtocolError, "preflight_identity_mismatch"):
            self.host.hello(hello, "nonce")

    def test_frame_authentication_duplicate_keys_sizes_and_float_safe_sequences(self):
        frame = transport.encode_frame(self.echo(), self.key)
        for wire, key, reason in ((frame, b"wrong" * 8, "authentication_failed"),
                                  (struct.pack("!I", transport.MAX_FRAME + 1), self.key, "frame_budget")):
            left, right = socket.socketpair()
            with left, right:
                left.sendall(wire)
                with self.assertRaisesRegex(transport.ProtocolError, reason):
                    transport.receive_frame(right, key)
        with self.assertRaisesRegex(transport.ProtocolError, "duplicate_json_key"):
            transport.strict_json(b'{"sequence":1,"sequence":2}')
        for sequence in (True, 0, transport.MAX_SEQUENCE + 1, 1.5):
            with self.subTest(sequence=sequence), self.assertRaises(transport.ProtocolError):
                self.echo(sequence)
        with self.assertRaises(transport.ProtocolError):
            transport.strict_json(b'{"value":NaN}')
        for wire in (b'{"text":"\\ud800"}', b'{"\\ud800":1}',
                     b'{"value":' + b'9' * 5000 + b'}'):
            with self.subTest(wire=wire[:32]), self.assertRaises(transport.ProtocolError):
                transport.strict_json(wire)
        malformed = self.echo()
        malformed["kind"] = []
        with self.assertRaisesRegex(transport.ProtocolError, "unsupported_request_kind"):
            self.host.receive(malformed)
        challenge = {"type": "challenge", "protocol": 1, "challenge": "nonce",
                     "epoch": "test-epoch-1", "identity_sha256": "a" * 64,
                     "authority": "evidence_only"}
        ready = {"type": "ready", "protocol": True, "epoch": "test-epoch-1",
                 "identity_sha256": "a" * 64, "authority": "evidence_only",
                 "last_sequence": 0}
        with mock.patch("mkmp_coordinator.receive_frame", side_effect=[challenge, ready]), \
                mock.patch("mkmp_coordinator.send_frame") as sent:
            with self.assertRaisesRegex(transport.ProtocolError, "invalid_host_ready"):
                request_connection(object(), self.key, self.client, self.echo())
            self.assertEqual(sent.call_count, 1, "malformed ready must not send a request")
        for file_id in ("..", "a:b", "CON", "con", "Client", "a/b"):
            with self.subTest(file_id=file_id), self.assertRaises(transport.ProtocolError):
                transport.file_identifier(file_id)

    def test_durable_write_failure_does_not_advance_in_memory_or_on_disk(self):
        before = self.host.path.read_bytes()
        with mock.patch.object(transport, "atomic_json", side_effect=OSError("injected disk failure")):
            with self.assertRaises(OSError):
                self.host.receive(self.echo())
        self.assertEqual(self.host.state["last_sequence"], 0)
        self.assertEqual(self.host.path.read_bytes(), before)
        self.assertFalse(self.host.receive(self.echo())["duplicate"])

    def test_corrupt_or_future_state_is_never_reset_to_an_empty_ledger(self):
        original = copy.deepcopy(self.host.state)
        for change in ({"schema": 99}, {"last_sequence": 1}, {"authority": "execute"}, {"schema": True}):
            candidate = {**original, **change}
            transport.atomic_json(self.host.path, candidate)
            with self.subTest(change=change), self.assertRaises(transport.ProtocolError):
                transport.HostStore(self.directory / "host")
            self.assertEqual(transport.load_json(self.host.path), candidate)

    def test_history_expiration_and_intent_budget_never_become_reexecution(self):
        with mock.patch.object(transport, "MAX_RECENT", 2):
            for sequence in range(1, 4):
                self.host.receive(self.echo(sequence))
            with self.assertRaisesRegex(transport.ProtocolError, "expired_receipt_no_replay"):
                self.host.receive(self.echo())
            intent = {"kind": "PapalLoan", "actor_faction": "mk_fact_test", "action_id": "explicit-candidate-1",
                      "phase": "inspection", "data": {"amount": "1000"}}
            with mock.patch.object(transport, "MAX_INTENTS", 1):
                ack = self.host.receive(transport.make_request("test-epoch-1", 4, "intent_candidate", intent))
                self.assertEqual(ack["result"]["execution"], "not_available")
                intent = {**intent, "action_id": "explicit-candidate-2"}
                with self.assertRaisesRegex(transport.ProtocolError, "intent_budget"):
                    self.host.receive(transport.make_request("test-epoch-1", 5, "intent_candidate", intent))
                self.assertEqual(self.host.state["last_sequence"], 4)

    def evidence_payload(self, data, offset, part, file_id="client-log"):
        return {"file_id": file_id, "name": "MK1212_mp_debug.log", "file_sha256": hashlib.sha256(data).hexdigest(),
                "total_bytes": len(data), "offset": offset, "data_base64": base64.b64encode(part).decode("ascii")}

    def test_evidence_is_opaque_checked_bytes_and_upload_progress_is_atomic_with_ack(self):
        # Deliberately includes apparent commands. They remain bytes; no parser
        # or execution mechanism interprets diagnostic contents as authority.
        content = b'MKMP|event=test\n{"execute":"PapalLoan"}\n'
        first = self.evidence_payload(content, 0, content[:12])
        request = self.client.prepare("evidence_part", first)
        ack = self.host.receive(request)
        malformed_ack = copy.deepcopy(ack)
        malformed_ack["result"]["complete"] = 0  # Equal to False in Python, but wrong wire type.
        with self.assertRaisesRegex(transport.ProtocolError, "invalid_evidence_ack_complete"):
            self.client.acknowledge(malformed_ack)
        with mock.patch.object(transport, "atomic_json", side_effect=OSError("client disk failure")):
            with self.assertRaises(OSError):
                self.client.acknowledge(ack)
        self.client = transport.ClientStore(self.directory / "client", "test-epoch-1", "a" * 64)
        self.assertEqual(self.client.state["uploads"], {})
        self.client.acknowledge(self.host.receive(self.client.state["pending"]))
        self.assertEqual(self.client.state["uploads"]["client-log"]["received_bytes"], 12)
        last = self.evidence_payload(content, 12, content[12:])
        request = self.client.prepare("evidence_part", last)
        self.client.acknowledge(self.host.receive(request))
        self.assertEqual(self.host.evidence_content(self.host.state["evidence"]["client-log"]), content)
        self.assertEqual(self.host.state["intents"], [])

    def test_bad_final_digest_does_not_store_unbounded_orphan_blobs(self):
        content = b"abcdef"
        self.host.receive(transport.make_request("test-epoch-1", 1, "evidence_part",
                                                self.evidence_payload(content, 0, b"abc")))
        before = set((self.directory / "host/evidence-blobs").iterdir())
        bad = self.evidence_payload(content, 3, b"BAD")
        with self.assertRaisesRegex(transport.ProtocolError, "evidence_file_digest_mismatch"):
            self.host.receive(transport.make_request("test-epoch-1", 2, "evidence_part", bad))
        self.assertEqual(set((self.directory / "host/evidence-blobs").iterdir()), before)
        self.assertEqual(self.host.state["last_sequence"], 1)

    def test_directory_has_one_owner(self):
        with transport.DirectoryLock(self.directory / "host"):
            with self.assertRaisesRegex(transport.ProtocolError, "state_directory_in_use"):
                with transport.DirectoryLock(self.directory / "host"):
                    self.fail("second owner acquired the same directory")

    def test_candidate_batch_freezes_membership_order_and_never_executes_after_both_receipts(self):
        def submit(action_id):
            payload = {"kind": "PapalLoan", "actor_faction": "mk_fact_test", "action_id": action_id,
                       "phase": "inspection", "data": {"amount": "1000"}}
            request = self.client.prepare("intent_candidate", payload)
            self.client.acknowledge(self.host.receive(request))
        submit("candidate-1")
        submit("candidate-2")
        freeze = self.client.prepare("batch_freeze", {})
        frozen_ack = self.host.receive(freeze)
        frozen = frozen_ack["result"]["batch"]
        frozen_digest = frozen["batch_sha256"]
        self.assertFalse(self.host.state["batches"][0]["client_seen"])
        with self.assertRaises(transport.ProtocolError):
            self.client.prepare("batch_ack", {"batch_id": "batch-1", "batch_sha256": frozen_digest, "count": 2})
        self.client.acknowledge(frozen_ack)
        submit("late-candidate")
        self.assertEqual(self.host.state["batches"][0]["frozen"]["count"], 2)
        self.assertEqual(self.host.state["batches"][0]["batch_sha256"], frozen_digest)
        request = self.client.prepare("batch_ack", {"batch_id": "batch-1", "batch_sha256": frozen_digest, "count": 2})
        ack = self.host.receive(request)
        self.client.acknowledge(ack)
        self.assertEqual(ack["result"]["state"], "ready_for_phase_proof")
        self.assertEqual(ack["result"]["execution"], "not_available")
        self.assertTrue(ack["result"]["host_seen"] and ack["result"]["client_seen"])
        # Updating a batch must not mutate the durable ACK of its earlier
        # freeze operation, including the response used for same-ID retries.
        repeated_freeze = self.host.receive(freeze)
        self.assertTrue(repeated_freeze["duplicate"])
        self.assertEqual(repeated_freeze["result"], frozen_ack["result"])
        self.assertEqual(repeated_freeze["result"]["batch"]["state"], "awaiting_client_receipt")
        request = self.client.prepare("batch_freeze", {})
        second_ack = self.host.receive(request)
        self.client.acknowledge(second_ack)
        second = second_ack["result"]["batch"]
        self.assertEqual([item["payload"]["action_id"] for item in second["frozen"]["items"]], ["late-candidate"])
        request = self.client.prepare("batch_abort", {"batch_id": "batch-2", "batch_sha256": second["batch_sha256"], "reason": "operator_cancelled"})
        self.client.acknowledge(self.host.receive(request))
        self.assertEqual(self.host.state["batches"][1]["state"], "aborted")
        self.assertEqual(self.host.state["batches"][1]["frozen"], second["frozen"])
        self.assertEqual(self.host.state["batches"][1]["abort_reason"], "operator_cancelled")
        # Caller-owned response dictionaries cannot mutate the frozen ledger.
        second["frozen"]["items"][0]["payload"]["kind"] = "changed_by_caller"
        self.assertEqual(self.host.state["batches"][1]["frozen"]["items"][0]["payload"]["kind"], "PapalLoan")

    def test_candidate_batch_conflict_membership_or_execution_state_is_rejected(self):
        intent = {"kind": "PapalLoan", "actor_faction": "mk_fact_test", "action_id": "candidate-1", "phase": "inspection", "data": {}}
        self.host.receive(transport.make_request("test-epoch-1", 1, "intent_candidate", intent))
        frozen = self.host.receive(transport.make_request("test-epoch-1", 2, "batch_freeze", {}))["result"]["batch"]
        before = self.host.path.read_bytes()
        bad_ack = {"batch_id": "batch-1", "batch_sha256": "b" * 64, "count": 1}
        with self.assertRaisesRegex(transport.ProtocolError, "batch_ack_digest_conflict"):
            self.host.receive(transport.make_request("test-epoch-1", 3, "batch_ack", bad_ack))
        self.assertEqual(self.host.path.read_bytes(), before)
        for field, value in (("state", "execute"), ("client_seen", True)):
            malformed = copy.deepcopy(frozen)
            malformed[field] = value
            with self.assertRaises(transport.ProtocolError):
                transport.validate_batch(malformed, "test-epoch-1")
        malformed = copy.deepcopy(frozen)
        malformed["frozen"]["members"] = ["HOST", "CLIENT", "OTHER"]
        malformed["batch_sha256"] = transport.digest(malformed["frozen"])
        with self.assertRaisesRegex(transport.ProtocolError, "batch_membership_changed"):
            transport.validate_batch(malformed, "test-epoch-1")


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mkmp-preflight-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        data = self.directory / "game/data"
        data.mkdir(parents=True)
        self.pack = data / ("mk1212_scripts_full_experimental_" + "a" * 12 + ".pack")
        self.pack.write_bytes(b"script-pack-test-bytes")
        (data / "base.pack").write_bytes(b"base-mod-test-bytes")
        (self.directory / "game/Attila.exe").write_bytes(b"test-exe-no-game-binary")
        (self.directory / "game/empire.retail.dll").write_bytes(b"test-module-no-game-binary")
        self.order = self.directory / "order.txt"
        self.order.write_text(f'mod "base.pack";\nmod "{self.pack.name}";\n', encoding="utf-8")
        self.manifest = self.directory / "pack.manifest.json"
        self.manifest.write_text(json.dumps({"schema": "mk1212-script-pack-v1", "schema_version": 1,
            "source_commit_sha": "a" * 40, "profile": {"name": "full-experimental"},
            "pack": {"filename": self.pack.name, "size": self.pack.stat().st_size,
                     "sha256": hashlib.sha256(self.pack.read_bytes()).hexdigest()}}), encoding="utf-8")
        self.args = {"game_directory": self.directory / "game", "manifest_path": self.manifest,
                     "pack_path": self.pack, "load_order_path": self.order, "game_build": "test-build",
                     "steam_branch": "public", "save_path": None, "new_campaign_key": "same-fixture",
                     "config_path": None, "config_absent": True, "native_path": None, "native_absent": True}

    def test_both_roles_share_identity_but_record_provenance_and_hashed_game_files(self):
        host = build_preflight(role="HOST", **self.args)
        client = build_preflight(role="CLIENT", **self.args)
        self.assertEqual(host["identity_sha256"], client["identity_sha256"])
        self.assertNotEqual(host["role"], client["role"])
        self.assertFalse(host["local_provenance"]["actual_engine_mod_order_verified"])
        self.assertEqual(host["compatibility"]["game"]["attila_exe"]["sha256"], hashlib.sha256(b"test-exe-no-game-binary").hexdigest())
        path = self.directory / "preflight.json"
        transport.atomic_json(path, host)
        self.assertEqual(load_preflight(path, "HOST"), host)

    def test_changed_pack_order_or_game_bytes_cannot_silently_match(self):
        first = build_preflight(role="HOST", **self.args)
        self.order.write_text(f'{self.pack.name}\nbase.pack\n', encoding="utf-8")
        second = build_preflight(role="HOST", **self.args)
        self.assertNotEqual(first["identity_sha256"], second["identity_sha256"])
        (self.directory / "game/empire.retail.dll").write_bytes(b"changed-game-module")
        third = build_preflight(role="HOST", **self.args)
        self.assertNotEqual(second["identity_sha256"], third["identity_sha256"])
        self.pack.write_bytes(b"changed-installed-overlay")
        with self.assertRaisesRegex(transport.ProtocolError, "pack_bytes_do_not_match_manifest"):
            build_preflight(role="CLIENT", **self.args)

    def test_missing_or_fabricated_empty_preflight_is_rejected(self):
        value = build_preflight(role="HOST", **self.args)
        value["compatibility"] = {}
        value["identity_sha256"] = transport.digest({})
        path = self.directory / "bad-preflight.json"
        transport.atomic_json(path, value)
        with self.assertRaisesRegex(transport.ProtocolError, "invalid_compatibility_fields"):
            load_preflight(path)
        (self.directory / "game/Attila.exe").unlink()
        with self.assertRaisesRegex(transport.ProtocolError, "required_file_missing:Attila.exe"):
            build_preflight(role="HOST", **self.args)


class DeliveryProbeTests(unittest.TestCase):
    def test_production_lua_probe_is_read_only_bounded_and_fail_soft(self):
        result = run_lua_fixture("scripts/ci/fixtures/mp_delivery_probe.lua")
        self.assertIn("delivery probe PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
