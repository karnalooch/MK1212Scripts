"""TurnObservationV1 source safety contract and optional Lua runtime fixture.
Run: python -m unittest scripts/ci/test_turn_observation_v1.py
If lua/lua5.1/luajit is on PATH, also executes the in-Lua behavior fixture.
"""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "campaigns/main_attila/common/mkmp_runtime.lua"
FIXTURE = ROOT / "scripts/ci/fixtures/turn_observation_v1.lua"

class TurnObservationV1Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_export_and_schema(self):
        self.assertIn("function MKMP_Runtime_Get_Turn_Observation_V1()", self.source)
        self.assertIn("function MKMP_Runtime_Get_Turn_Observation_Event_V1(event_name)", self.source)
        self.assertIn('schema = 1', self.source)
        for field in ("local_faction", "active_faction", "phase", "input_enabled",
                      "local_player_index", "active_player_index"):
            self.assertIn(field + ' = "unknown"', self.source)

    def test_observation_no_native_authority_or_mutation(self):
        tail = self.source.split("-- Issue #35: observational state only.", 1)[1]
        for forbidden in ("MH_CreateHook", "VirtualProtect", "SetActiveTurn",
                          "SetTreasury", "GetMemoryAddress", "require(", "loadstring("):
            self.assertNotIn(forbidden, tail)
        self.assertIn("pcall(", tail)

    def test_product_probe_emits_read_only_turn_events_and_coverage(self):
        harness = (ROOT / "scripts/runtime/RUN-MK1212-PR45-SP-TEST.ps1").read_text(encoding="utf-8")
        self.assertIn('Probe_Turn("initializer", nil)', harness)
        self.assertIn('Probe_Turn("faction_turn_start", context)', harness)
        self.assertIn('if turn_samples >= 32 then return; end', harness)
        self.assertIn('event_faction=', harness)
        self.assertIn("coverage.json", harness)
        self.assertIn("simultaneous_turns_proven = $false", harness)
        self.assertIn("active_owner_proven = $false", harness)
        self.assertIn("OBSERVED_CALLBACK_ONLY", harness)
        self.assertLess(harness.index("# Coverage is evidence accounting"), harness.index("$Result | ConvertTo-Json"))
        self.assertIn("finally {", harness)
        self.assertIn("rollback_ok", harness)

    def test_flight_recorder_is_bounded_and_read_only(self):
        harness = (ROOT / "scripts/runtime/RUN-MK1212-PR45-SP-TEST.ps1").read_text(encoding="utf-8")
        self.assertIn("AEEF Flight Recorder V1", harness)
        self.assertIn("local flight_limit = 48;", harness)
        self.assertIn('"FactionTurnStart", "FactionTurnEnd"', harness)
        self.assertIn('Flight_Record("initializer", nil)', harness)
        self.assertIn("owner=unknown phase=unknown", harness)
        self.assertIn("flight_recorder", harness)
        self.assertIn("sequence_valid", harness)
        self.assertNotIn("SetActiveFaction", harness)
        self.assertNotIn("SetActiveTurn", harness)
        self.assertNotIn("VirtualProtect", harness)

    def test_lua_behavior_fixture(self):
        lua = next((shutil.which(x) for x in ("lua5.1", "lua", "luajit") if shutil.which(x)), None)
        if not lua:
            self.skipTest("Lua interpreter not on PATH; static contracts still verified")
        run = subprocess.run([lua, str(FIXTURE), str(SOURCE)],
                             capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

if __name__ == "__main__":
    unittest.main()
