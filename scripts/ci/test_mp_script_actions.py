"""Production-Lua campaign action regressions, with fake Attila interfaces."""
from __future__ import annotations

import unittest

from lua_test_runtime import run_lua_fixture


class ScriptActionLuaTests(unittest.TestCase):
    def run_scenario(self, name: str) -> None:
        result = run_lua_fixture("scripts/ci/fixtures/mp_script_actions.lua", name)
        self.assertIn(f"PASS production Lua script actions: {name}", result.stdout)

    def test_initializer_is_once_in_sp_and_mp(self) -> None:
        self.run_scenario("initializer_once")

    def test_local_difficulty_cannot_drive_mp_weariness_but_sp_scaling_remains(self) -> None:
        self.run_scenario("local_difficulty_is_not_shared_authority")

    def test_real_lua_dual_peer_turn_mutations_and_save_reload_match(self) -> None:
        self.run_scenario("dual_peer_turns_and_save")

    def test_legacy_saves_migrate_without_replaying_gameplay(self) -> None:
        self.run_scenario("old_save_migration")

    def test_reentrant_or_partially_failed_mutations_are_not_retried(self) -> None:
        self.run_scenario("reentry_and_partial_failure")

    def test_unknown_corrupt_or_unbounded_turn_metadata_is_preserved(self) -> None:
        self.run_scenario("invalid_turn_metadata")

    def test_battle_results_validate_before_either_side_changes(self) -> None:
        self.run_scenario("battle_result_validation")

    def test_mecca_raze_listener_does_not_collide_and_actor_survives_reload(self) -> None:
        self.run_scenario("mecca_listener_and_raze_persistence")

    def test_mecca_missing_entities_never_select_another_actor(self) -> None:
        self.run_scenario("mecca_invalid_entities")


if __name__ == "__main__":
    unittest.main(verbosity=2)
