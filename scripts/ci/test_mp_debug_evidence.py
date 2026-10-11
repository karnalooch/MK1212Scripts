from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from compare_mp_debug_logs import compare_records, parse_line  # noqa: E402


class MPDebugEvidenceTests(unittest.TestCase):
    def test_empty_logs_are_not_matching_evidence(self) -> None:
        matched, message = compare_records([], [])
        self.assertFalse(matched)
        self.assertIn("INSUFFICIENT EVIDENCE", message)
        self.assertIn("host_semantic_records=0 client_semantic_records=0", message)

    def test_pr45_native_single_player_bootstrap_is_not_mp_evidence(self) -> None:
        # Actual first segment shape from the 2026-10-08 native PR45 SP archive.
        # The archive has three such segments and no shared semantic records.
        lines = [
            "MKMP|v=1|seq=1|turn=unknown|event=session_begin|existing_bytes=0|"
            "local_faction=unknown|multiplayer=false|path=MK1212_mp_debug.log|schema=1",
            "MKMP|v=1|seq=2|turn=unknown|event=runtime|available=true|"
            "load_candidate=twdll_attila.dll|message=ready game=Attila "
            "twdll_sha=bf8b4ec9357dca56f9e71c3a5407c9db574de0fd factions=nil "
            "load_candidate=twdll_attila.dll|reason=ready|"
            "twdll_sha=bf8b4ec9357dca56f9e71c3a5407c9db574de0fd",
        ]
        records = [parse_line(line, i) for i, line in enumerate(lines, start=1)]
        matched, message = compare_records(records, records)
        self.assertFalse(matched)
        self.assertIn("INSUFFICIENT EVIDENCE", message)
        self.assertIn("bootstrap alone", message)

    def test_only_one_peer_has_semantic_records(self) -> None:
        record = parse_line(
            "MKMP|v=1|seq=2|turn=1|event=barrier|name=faction_turn_start"
        )
        for host, client in (([record], []), ([], [record])):
            with self.subTest(host_count=len(host), client_count=len(client)):
                matched, message = compare_records(host, client)
                self.assertFalse(matched)
                self.assertIn("INSUFFICIENT EVIDENCE", message)

    def test_content_identity_alone_is_not_shared_execution(self) -> None:
        records = [
            parse_line("MKMP|v=1|seq=1|turn=unknown|event=session_begin|multiplayer=true"),
            parse_line(
                "MKMP|v=1|seq=2|turn=unknown|event=content_identity|"
                "source=" + "a" * 40 + "|profile=baseline|multiplayer=true|save_schema=3"
            ),
            parse_line("MKMP|v=1|seq=3|turn=unknown|event=runtime|available=false"),
        ]
        matched, message = compare_records(records, records)
        self.assertFalse(matched)
        self.assertIn("INSUFFICIENT EVIDENCE", message)
        self.assertIn("host_semantic_records=0 client_semantic_records=0", message)

    def test_content_source_and_profile_mismatches_are_visible(self) -> None:
        identity = (
            "MKMP|v=1|seq=2|turn=unknown|event=content_identity|source="
            + "a" * 40 + "|profile=baseline|multiplayer=true|save_schema=3"
        )
        action = parse_line("MKMP|v=1|seq=3|turn=1|event=barrier|name=faction_turn_start")
        host = [parse_line(identity), action]
        for altered in (
            identity.replace("a" * 40, "b" * 40),
            identity.replace("profile=baseline", "profile=full-experimental"),
            identity.replace("multiplayer=true", "multiplayer=false"),
            identity.replace("save_schema=3", "save_schema=2"),
        ):
            with self.subTest(identity=altered):
                for host_records, client_records in (
                    (host, [parse_line(altered), action]),
                    ([host[0]], [parse_line(altered)]),
                ):
                    matched, message = compare_records(host_records, client_records)
                    self.assertFalse(matched)
                    self.assertIn("FIRST DIVERGENCE", message)
                    self.assertIn("content_identity", message)

    def test_identity_cannot_be_missing_on_only_one_peer(self) -> None:
        identity = parse_line(
            "MKMP|v=1|seq=2|turn=unknown|event=content_identity|source="
            + "a" * 40 + "|profile=baseline|multiplayer=true|save_schema=3"
        )
        action = parse_line("MKMP|v=1|seq=3|turn=1|event=barrier|name=faction_turn_start")
        matched, message = compare_records([identity, action], [action])
        self.assertFalse(matched)
        self.assertIn("FIRST DIVERGENCE", message)

    def test_identical_identity_and_actions_keep_limited_trace_result(self) -> None:
        records = [
            parse_line(
                "MKMP|v=1|seq=2|turn=unknown|event=content_identity|source="
                + "a" * 40 + "|profile=baseline|multiplayer=true|save_schema=3"
            ),
            parse_line("MKMP|v=1|seq=3|turn=1|event=barrier|name=faction_turn_start"),
        ]
        matched, message = compare_records(records, records)
        self.assertTrue(matched, message)
        self.assertIn("runtime_mp_proof=not_established", message)

    def test_match_explicitly_limits_the_proof_scope(self) -> None:
        record = parse_line(
            "MKMP|v=1|seq=2|turn=1|event=barrier|name=faction_turn_start"
        )
        matched, message = compare_records([record], [record])
        self.assertTrue(matched, message)
        self.assertIn("semantic_records=1", message)
        self.assertIn("scope=instrumented_semantic_trace", message)
        self.assertIn("runtime_mp_proof=not_established", message)

    def test_unknown_or_malformed_log_version_is_rejected(self) -> None:
        for version in ("", "0", "2", "01", "1.0", "unknown"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, "unsupported log schema"):
                    parse_line(
                        f"MKMP|v={version}|seq=1|turn=1|event=barrier|name=test"
                    )

    def test_missing_core_fields_are_rejected(self) -> None:
        fields = ["v=1", "seq=1", "turn=1", "event=barrier"]
        for missing in range(len(fields)):
            with self.subTest(missing=fields[missing]):
                with self.assertRaisesRegex(ValueError, "missing required fields"):
                    parse_line("MKMP|" + "|".join(fields[:missing] + fields[missing + 1 :]))

    def test_duplicate_fields_cannot_replace_prior_evidence(self) -> None:
        for duplicate in ("v=2", "event=runtime", "result=99"):
            with self.subTest(duplicate=duplicate):
                with self.assertRaisesRegex(ValueError, "line 7: duplicate field"):
                    parse_line(
                        "MKMP|v=1|seq=1|turn=1|event=rng|result=5|" + duplicate,
                        7,
                    )

    def test_supported_log_schema_keeps_independent_save_schema(self) -> None:
        record = parse_line(
            "MKMP|v=1|seq=1|turn=unknown|event=save_write|schema=2|"
            "name=pending_regions|entries=0|bytes=0"
        )
        self.assertEqual(record.fields["v"], "1")
        self.assertEqual(record.fields["schema"], "2")

    def test_unknown_or_truncated_escapes_are_rejected(self) -> None:
        prefix = "MKMP|v=1|seq=1|turn=1|event=vassal|message="
        for value in (r"unknown\q", "truncated\\"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "escape"):
                    parse_line(prefix + value)

    def test_empty_event_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "empty event"):
            parse_line("MKMP|v=1|seq=1|turn=1|event=")


if __name__ == "__main__":
    unittest.main(verbosity=2)
