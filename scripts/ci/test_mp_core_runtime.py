"""Run actual production Lua: mocked engine boundary, real codec/RNG code."""
import unittest

from lua_test_runtime import run_lua_fixture


class CoreProductionLuaTests(unittest.TestCase):
    def test_canonical_roundtrip_and_content_diagnostics(self):
        run_lua_fixture("scripts/ci/fixtures/mp_core_runtime.lua", "roundtrip")

    def test_legacy_schema_migration_preserves_literal_data(self):
        run_lua_fixture("scripts/ci/fixtures/mp_core_runtime.lua", "legacy")

    def test_invalid_save_and_load_refuse_before_replacing_good_state(self):
        run_lua_fixture("scripts/ci/fixtures/mp_core_runtime.lua", "refusals")

    def test_population_decisions_and_nicknames_use_real_codec(self):
        run_lua_fixture("scripts/ci/fixtures/mp_core_runtime.lua", "custom")

    def test_rng_requires_finite_integer_bounds_and_results(self):
        run_lua_fixture("scripts/ci/fixtures/mp_core_runtime.lua", "rng")

    def test_peer_local_difficulty_cannot_select_shared_scripted_armies(self):
        run_lua_fixture("scripts/ci/fixtures/mp_core_runtime.lua", "difficulty")

    def test_encoding_refuses_during_accumulation_before_large_copies_or_writes(self):
        run_lua_fixture("scripts/ci/fixtures/mp_core_runtime.lua", "budgets")

    def test_region_queue_reload_and_partial_failure_preserve_later_work(self):
        run_lua_fixture("scripts/ci/fixtures/mp_core_runtime.lua", "region_queue")

    def test_real_logger_failure_cannot_interrupt_campaign_rng_or_save(self):
        run_lua_fixture("scripts/ci/fixtures/mp_core_runtime.lua", "logger")
