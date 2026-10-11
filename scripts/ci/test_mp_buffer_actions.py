"""Production buffer-state action lifecycles with fake Attila boundaries."""
from __future__ import annotations

import unittest

from lua_test_runtime import run_lua_fixture


class BufferActionLuaTests(unittest.TestCase):
    def run_scenario(self, name: str) -> None:
        result = run_lua_fixture("scripts/ci/fixtures/mp_buffer_actions.lua", name)
        self.assertIn(f"PASS production Lua buffer actions: {name}", result.stdout)

    def test_confirmation_captures_target_and_duplicates_apply_once(self) -> None:
        self.run_scenario("captured_target_and_duplicates")

    def test_stale_and_legacy_timer_cannot_consume_next_action(self) -> None:
        self.run_scenario("stale_timer_cannot_consume_next_action")

    def test_waiting_save_load_restores_only_transfer_without_setup_replay(self) -> None:
        self.run_scenario("waiting_save_reload")

    def test_started_or_partially_failed_setup_is_never_replayed(self) -> None:
        self.run_scenario("interrupted_setup_is_not_replayed")

    def test_transfer_refusal_failure_and_reentry_keep_single_claim(self) -> None:
        self.run_scenario("transfer_failure_claims_once")

    def test_target_owner_entities_and_spawn_result_are_revalidated(self) -> None:
        self.run_scenario("expected_owner_and_entities")

    def test_already_owned_noop_and_sp_revived_faction_path(self) -> None:
        self.run_scenario("already_owned_and_revived_faction")

    def test_legacy_save_and_cancelled_intent_cannot_guess_a_target(self) -> None:
        self.run_scenario("legacy_and_unconfirmed_intent")

    def test_unknown_malformed_oversized_metadata_and_serial_exhaustion(self) -> None:
        self.run_scenario("metadata_bounds_and_exhaustion")


if __name__ == "__main__":
    unittest.main(verbosity=2)
