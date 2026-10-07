from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from compare_mp_debug_logs import (  # noqa: E402
    compare_files,
    compare_records,
    parse_line,
)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class MPDebugLoggingTests(unittest.TestCase):
    def test_parser_handles_escaped_single_line_values(self) -> None:
        record = parse_line(
            r"MKMP|v=1|seq=4|turn=12|event=vassal|message=A\|B\\C\nD",
            7,
        )
        self.assertEqual(record.line_number, 7)
        self.assertEqual(record.event, "vassal")
        self.assertEqual(record.fields["message"], "A|B\\C\nD")

    def test_peer_comparator_ignores_session_runtime_and_process_local_fields(self) -> None:
        host = [
            parse_line(
                "MKMP|v=1|seq=1|turn=1|event=session_begin|local_faction=host|path=A",
                1,
            ),
            parse_line(
                "MKMP|v=1|seq=2|turn=1|event=runtime|available=true|reason=ready",
                2,
            ),
            parse_line(
                "MKMP|v=1|seq=3|turn=1|event=barrier|name=faction_turn_start|"
                "faction=mk_fact_test|battle_address=0x1111",
                3,
            ),
        ]
        client = [
            parse_line(
                "MKMP|v=1|seq=1|turn=1|event=session_begin|local_faction=client|path=B",
                1,
            ),
            parse_line(
                "MKMP|v=1|seq=2|turn=1|event=runtime|available=false|reason=dll_missing",
                2,
            ),
            parse_line(
                "MKMP|v=1|seq=9|turn=1|event=barrier|name=faction_turn_start|"
                "faction=mk_fact_test|battle_address=0xAAAA",
                3,
            ),
        ]

        matched, message = compare_records(host, client)
        self.assertTrue(matched, message)

    def test_peer_comparator_reports_first_semantic_divergence(self) -> None:
        host = [
            parse_line(
                "MKMP|v=1|seq=10|turn=15|event=rng|token=mongols.spawn_x|"
                "minimum=400|maximum=420|result=412",
                1,
            )
        ]
        client = [
            parse_line(
                "MKMP|v=1|seq=22|turn=15|event=rng|token=mongols.spawn_x|"
                "minimum=400|maximum=420|result=417",
                1,
            )
        ]

        matched, message = compare_records(host, client)
        self.assertFalse(matched)
        self.assertIn("FIRST DIVERGENCE", message)
        self.assertIn("semantic_index=0", message)
        self.assertIn("412", message)
        self.assertIn("417", message)

    def test_file_comparator_round_trip(self) -> None:
        host_text = "\n".join(
            [
                "MKMP|v=1|seq=1|turn=1|event=session_begin|local_faction=A",
                "MKMP|v=1|seq=2|turn=1|event=save_write|bytes=12|entries=2|name=test|schema=2",
            ]
        )
        client_text = "\n".join(
            [
                "MKMP|v=1|seq=5|turn=1|event=session_begin|local_faction=B",
                "MKMP|v=1|seq=9|turn=1|event=save_write|bytes=12|entries=2|name=test|schema=2",
            ]
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            host = Path(temp_dir) / "host.log"
            client = Path(temp_dir) / "client.log"
            host.write_text(host_text, encoding="utf-8")
            client.write_text(client_text, encoding="utf-8")
            matched, message = compare_files(host, client)

        self.assertTrue(matched, message)

    def test_logger_source_is_bounded_append_only_and_fail_soft(self) -> None:
        source = read("campaigns/main_attila/common/mkmp_debug.lua")

        self.assertIn('MKMP_DEBUG_LOG_PATH = "MK1212_mp_debug.log";', source)
        self.assertIn("MKMP_DEBUG_MAX_ENTRIES = 100000;", source)
        self.assertIn("MKMP_DEBUG_MAX_BYTES = 16777216;", source)
        self.assertIn('io.open(MKMP_DEBUG_LOG_PATH, "a")', source)
        self.assertIn("file:close();", source)
        self.assertIn('MKMP_Debug_Disable("entry_budget_exhausted")', source)
        self.assertIn('MKMP_Debug_Disable("byte_budget_exhausted")', source)
        self.assertIn('MKMP_Debug_Disable("open_failed:"', source)
        self.assertIn('MKMP_Debug_Disable("write_failed:"', source)
        self.assertNotIn('io.open(MKMP_DEBUG_LOG_PATH, "w")', source)

    def test_production_runtime_initializes_and_uses_debug_sink(self) -> None:
        main = read("campaigns/main_attila/common/main.lua")
        runtime = read("campaigns/main_attila/common/mkmp_runtime.lua")
        common = read("campaigns/main_attila/common/mk1212_common.lua")
        vassal = read("campaigns/main_attila/common/mk1212_vassal_tracking.lua")

        self.assertIn('require("common/mkmp_debug");', main)
        self.assertIn("MKMP_Debug_Initialize();", main)
        self.assertIn("pcall(", runtime)
        self.assertIn("MKMP_Debug_Log,", runtime)
        self.assertIn('"runtime"', runtime)
        self.assertIn('"rng"', common)
        self.assertIn('"faction_turn_start"', common)
        self.assertIn('"faction_turn_end"', common)
        self.assertIn('"region_transfer_queued"', common)
        self.assertIn('"region_transfer_apply"', common)
        self.assertIn('"save_write"', common)
        self.assertIn('MKMP_Debug_Log(\n\t\t\t"vassal"', vassal)

    def test_debug_file_is_never_loaded_as_gameplay_input(self) -> None:
        runtime_sources = [
            read("campaigns/main_attila/common/mkmp_debug.lua"),
            read("campaigns/main_attila/common/main.lua"),
            read("campaigns/main_attila/common/mk1212_common.lua"),
            read("campaigns/main_attila/common/mk1212_vassal_tracking.lua"),
        ]
        joined = "\n".join(runtime_sources)

        # The logger may open the file as rb only to measure the existing byte
        # budget; there must be no line parser/load path for debug records.
        self.assertNotIn("load_debug", joined.lower())
        self.assertNotIn("read_debug", joined.lower())
        self.assertNotIn("MKMP_Debug_Load", joined)


if __name__ == "__main__":
    unittest.main(verbosity=2)
