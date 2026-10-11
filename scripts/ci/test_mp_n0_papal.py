"""One consolidated run for the Papal fixes and nickname ordering contract."""
from __future__ import annotations

import unittest

from lua_test_runtime import run_lua_fixture


class PapalNicknameLuaTests(unittest.TestCase):
    def test_production_transitions_claims_reload_and_rng_order(self) -> None:
        result = run_lua_fixture("scripts/ci/fixtures/mp_n0_papal.lua")
        self.assertIn("PASS production Lua Papal and nickname regressions", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
