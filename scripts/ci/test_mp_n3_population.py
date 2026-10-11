"""One consolidated production-Lua Population accounting/action regression."""
from __future__ import annotations

import unittest

from lua_test_runtime import run_lua_fixture


class PopulationActionLuaTests(unittest.TestCase):
    def test_production_reservations_observations_and_mp_gate(self) -> None:
        result = run_lua_fixture("scripts/ci/fixtures/mp_n3_population.lua")
        self.assertIn("PASS production Lua population reservation and observation regressions", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
