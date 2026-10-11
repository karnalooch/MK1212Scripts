"""One consolidated production action lifecycle run with fake Attila boundaries."""
from __future__ import annotations

import unittest

from lua_test_runtime import run_lua_fixture


class BufferActionLuaTests(unittest.TestCase):
    def test_sp_action_lifecycles_and_mp_capture_only_boundary(self) -> None:
        result = run_lua_fixture("scripts/ci/fixtures/mp_buffer_actions.lua", "all")
        # All original safety scenarios remain inside the Lua run. Reuse one
        # interpreter invocation for the correlated ledger/save/load additions.
        expected = {
            "captured_target_and_duplicates", "stale_timer_cannot_consume_next_action",
            "waiting_save_reload", "interrupted_setup_is_not_replayed",
            "transfer_failure_claims_once", "expected_owner_and_entities",
            "already_owned_and_revived_faction", "legacy_and_unconfirmed_intent",
            "metadata_bounds_and_exhaustion", "legacy_v1_migration_and_mp_capture_only",
            "annex_handover_claim_survives_failure_turn_and_load",
            "region_trade_observes_exact_payload_without_replay",
        }
        observed = {
            line.removeprefix("PASS production Lua buffer actions: ")
            for line in result.stdout.splitlines()
            if line.startswith("PASS production Lua buffer actions: ")
        }
        self.assertEqual(expected, observed)
        self.assertIn(f"PASS production Lua action scenarios: {len(expected)}", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
