from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from compare_mp_debug_logs import (  # noqa: E402
    LogRecord, compare_records, decode_fingerprint, load_log, parse_line,
)
from lua_test_runtime import run_lua_fixture  # noqa: E402


class MPN1DiagnosticsTests(unittest.TestCase):
    """One production execution feeds all focused evidence-format assertions."""

    @classmethod
    def setUpClass(cls) -> None:
        result = run_lua_fixture("scripts/ci/fixtures/mp_n1_diagnostics.lua")
        cls.logs: dict[str, list[LogRecord]] = {}
        cls.raw_logs: dict[str, str] = {}
        active: str | None = None
        lines: list[str] = []
        cls.payload = ""
        for line in result.stdout.splitlines():
            if line.startswith("N1_BEGIN:"):
                active, lines = line.removeprefix("N1_BEGIN:"), []
            elif line.startswith("N1_END:"):
                assert active == line.removeprefix("N1_END:")
                cls.raw_logs[active] = "\n".join(lines) + "\n"
                cls.logs[active] = [parse_line(value, i) for i, value in enumerate(lines, 1)]
                active = None
            elif active is not None:
                lines.append(line)
            elif line.startswith("N1_PAYLOAD:"):
                cls.payload = line.removeprefix("N1_PAYLOAD:")
        assert "PASS production Lua N1" in result.stdout

    def test_real_ww_logger_parser_and_asymmetric_local_events(self) -> None:
        turns = [row for row in self.logs["HOST"] if row.event == "war_weariness_turn"]
        self.assertEqual(len(turns), 1)
        self.assertEqual(turns[0].turn, "1")
        self.assertNotIn("payload_rejected", turns[0].fields)
        matched, message = compare_records(self.logs["HOST"], self.logs["CLIENT"])
        self.assertTrue(matched, message)
        self.assertIn("runtime_mp_proof=not_established", message)
        self.assertIn("complete_checkpoints=2", message)
        rng = next(row for row in self.logs["HOST"] if row.event == "rng")
        self.assertEqual(rng.fields["rng_coverage"], "wrapped_only")
        self.assertEqual(rng.fields["rng_ordinal"], "1")

    def test_equal_counts_different_region_owner_has_first_key_difference(self) -> None:
        matched, message = compare_records(self.logs["HOST"], self.logs["SWAPPED"])
        self.assertFalse(matched)
        self.assertIn("FIRST DIVERGENCE", message)
        self.assertIn("component_path", message)
        self.assertIn("owners", message)
        self.assertIn("att_reg_a", message)
        self.assertIn("payload_sha256", message)

    def test_reserved_core_fields_cannot_override_header(self) -> None:
        row = next(row for row in self.logs["RESERVED"] if row.event == "reserved_test")
        self.assertEqual(row.fields["v"], "1")
        self.assertEqual(row.fields["turn"], "1")
        self.assertEqual(row.fields["segment"], "0")
        self.assertEqual(row.fields["trace_schema"], "1")
        self.assertEqual(row.fields["payload_rejected"], "7")
        with self.assertRaisesRegex(ValueError, "duplicate field"):
            parse_line("MKMP|v=1|seq=1|turn=1|event=bad|turn=2")

    def test_load_segments_reset_refs_and_do_not_stitch_unrelated_runs(self) -> None:
        matched, message = compare_records(self.logs["HOST_LOAD"], self.logs["CLIENT_LOAD"])
        self.assertTrue(matched, message)
        self.assertIn("complete_checkpoints=4", message)
        incomplete = [row for row in self.logs["CLIENT_LOAD"] if row.event != "segment_begin"]
        matched, message = compare_records(self.logs["HOST_LOAD"], incomplete)
        self.assertFalse(matched)
        self.assertIn("INSUFFICIENT EVIDENCE", message)

    def test_missing_truncated_corrupt_or_unresolved_components_cannot_pass(self) -> None:
        for rows in (self.logs["MISSING"], self.logs["HOST"][:-1]):
            with self.subTest(last_event=rows[-1].event):
                matched, message = compare_records(rows, rows)
                self.assertFalse(matched)
                self.assertIn("INSUFFICIENT EVIDENCE", message)
        rows = list(self.logs["HOST"])
        index = next(i for i, row in enumerate(rows) if row.fields.get("payload_mode") == "unchanged")
        fields = dict(rows[index].fields, payload_ref="999")
        rows[index] = LogRecord(rows[index].line_number, fields)
        matched, message = compare_records(rows, rows)
        self.assertFalse(matched)
        self.assertIn("payload reference", message)
        corrupted = list(self.logs["HOST"])
        index = next(i for i, row in enumerate(corrupted) if row.fields.get("payload_mode") == "inline")
        fields = dict(corrupted[index].fields, checksum="adler32-v1:00000000")
        corrupted[index] = LogRecord(corrupted[index].line_number, fields)
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            compare_records(corrupted, corrupted)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "truncated.log"
            path.write_text(self.raw_logs["HOST"].rstrip("\n"), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "newline terminator"):
                load_log(path)

    def test_canonical_float_binary_string_and_typed_keys_decode(self) -> None:
        leaves, entries = decode_fingerprint(self.payload)
        self.assertGreater(entries, 1)
        self.assertIn("$[n:1]", leaves)
        self.assertIn("$[s:'1']", leaves)
        self.assertNotEqual(leaves["$[n:1]"], leaves["$[s:'1']"])
        self.assertTrue(any("0.100000" in value for value in leaves.values()))
        self.assertTrue(any("\\x00" in value and "\\xff" in value for value in leaves.values()))
        for invalid in ("MKFP2;m0:", "MKFP1;m1:", "MKFP1;m0:trailing"):
            with self.subTest(payload=invalid), self.assertRaises(ValueError):
                decode_fingerprint(invalid)


if __name__ == "__main__":
    unittest.main(verbosity=2)
