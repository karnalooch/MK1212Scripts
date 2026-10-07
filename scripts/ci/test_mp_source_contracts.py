from __future__ import annotations

import re
import unittest
from pathlib import Path

from mp_simulation import CONTRACTS, ROOT


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class MultiplayerSourceContractTests(unittest.TestCase):
    def test_campaign_runtime_has_no_lua_math_random(self) -> None:
        offenders: list[str] = []
        for path in sorted((ROOT / "campaigns").rglob("*.lua")):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                code = line.split("--", 1)[0]
                if re.search(r"\bmath\.random(?:seed)?\b", code):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_rng_gameplay_ranges_match_audited_upstream_contract(self) -> None:
        common = read("campaigns/main_attila/common/mk1212_common.lua")
        greek = read("campaigns/main_attila/byzantium/byzantium_greek_fire.lua")
        mongol = read("campaigns/main_attila/mongols/mongol_invasion.lua")
        timurid = read("campaigns/main_attila/timurids/timurid_invasion.lua")

        heir = CONTRACTS["rng_contracts"]["heir_age"]
        greek_contract = CONTRACTS["rng_contracts"]["greek_fire_damage"]

        self.assertIn(
            f'MK1212_Random_Int({heir["minimum"]}, {heir["maximum"]}, "common.heir_age:',
            common,
        )
        self.assertIn(
            f'MK1212_Random_Int({greek_contract["minimum"]}, {greek_contract["maximum"]}, "greek_fire.damage:',
            greek,
        )
        self.assertIn('MK1212_Random_Int(zone.x1, zone.x2, "mongols.spawn_x:', mongol)
        self.assertIn('MK1212_Random_Int(zone.y2, zone.y1, "mongols.spawn_y:', mongol)
        self.assertIn('MK1212_Random_Int(zone.x1, zone.x2, "timurids.spawn_x:', timurid)
        self.assertIn('MK1212_Random_Int(zone.y2, zone.y1, "timurids.spawn_y:', timurid)

    def test_mp_feature_gates_are_campaign_runtime_authority(self) -> None:
        challenges = read("campaigns/main_attila/challenges/main.lua")
        ironman = read("campaigns/main_attila/ironman/main.lua")
        lucky = read("campaigns/main_attila/luckynations/main.lua")

        self.assertIn("if cm:is_multiplayer() then", challenges)
        self.assertIn('CHALLENGES_ENABLED["judgement_day"] = false;', challenges)
        self.assertIn('CHALLENGES_ENABLED["no_retreat"] = false;', challenges)
        self.assertIn('CHALLENGES_ENABLED["this_is_total_war"] = false;', challenges)

        self.assertRegex(
            ironman,
            r"function Ironman_Initializer\(\)\s+if cm:is_multiplayer\(\) then\s+IRONMAN_ENABLED = false;\s+return;",
        )
        self.assertRegex(
            lucky,
            r"function Lucky_Nations_Initializer\(\)\s+if cm:is_multiplayer\(\) then\s+LUCKY_NATIONS_ENABLED = false;\s+return;",
        )

    def test_vassal_model_reconciliation_has_no_real_time_vassal_trigger(self) -> None:
        source = read("campaigns/main_attila/common/mk1212_vassal_tracking.lua")
        self.assertNotIn('cm:add_time_trigger("vassal_check"', source)
        self.assertNotIn('cm:add_time_trigger("diplo_vassal_check"', source)
        self.assertNotIn("function TimeTrigger_Vassal_Tracking", source)
        self.assertIn("function Process_Pending_Vassal_Operations", source)
        self.assertIn("PENDING_LIBERATION_CHECKS", source)
        self.assertIn("PENDING_SUBJUGATIONS", source)
        self.assertIn("PENDING_DIPLO_EVENTS", source)

    def test_common_save_serializers_are_canonical_and_bounded(self) -> None:
        source = read("campaigns/main_attila/common/mk1212_common.lua")
        limits = CONTRACTS["save_limits"]

        self.assertIn("function MK1212_SaveSortedKeys", source)
        self.assertIn("function MK1212_SaveCommitString", source)
        self.assertIn(f'MK1212_SAVE_MAX_ENTRIES = {limits["max_entries"]};', source)
        self.assertIn(
            f'MK1212_SAVE_MAX_STRING_BYTES = {limits["max_string_bytes"]};',
            source,
        )
        for function in (
            "SaveKeyPairTable",
            "SaveBooleanPairTable",
            "SaveKeyPairTables",
        ):
            start = source.index(f"function {function}")
            end = source.find("\nfunction ", start + 1)
            block = source[start:] if end == -1 else source[start:end]
            self.assertIn("MK1212_SaveSortedKeys", block, function)
            self.assertIn("MK1212_SaveCommitString", block, function)

    def test_deferred_region_transfer_is_bounded_and_persisted(self) -> None:
        source = read("campaigns/main_attila/common/mk1212_common.lua")
        max_pending = CONTRACTS["region_transfer"]["max_pending"]

        self.assertIn("REGIONS_TO_TRANSFER = {};", source)
        self.assertIn(f"MAX_PENDING_REGION_TRANSFERS = {max_pending};", source)
        self.assertIn("function Queue_Region_Transfer", source)
        self.assertIn("Serialize_Region_Transfer_Queue", source)
        self.assertIn("Load_Region_Transfer_Queue", source)
        self.assertIn(
            'SaveTable(context, Serialize_Region_Transfer_Queue(), "REGIONS_TO_TRANSFER");',
            source,
        )

    def test_hardcoded_limit_mutation_is_blocked_inside_multiplayer(self) -> None:
        source = read("campaigns/main_attila/mk1212_slots.lua")
        self.assertIn("function MK1212_Get_Hardcoded_Limits_Fingerprint", source)
        self.assertIn("function ModifyHardcodedLimits()", source)
        self.assertIn(
            "ModifyHardcodedLimits blocked during multiplayer campaign runtime",
            source,
        )
        block_start = source.index("function ModifyHardcodedLimits()")
        block = source[block_start : block_start + 500]
        self.assertIn("if cm:is_multiplayer() then", block)
        self.assertIn("return false;", block)

    def test_twdll_adapter_is_optional_and_filters_raw_battle_addresses(self) -> None:
        source = read("campaigns/main_attila/common/mkmp_runtime.lua")
        self.assertIn("package.loadlib", source)
        self.assertIn("pcall(", source)
        self.assertIn('MKMP_RUNTIME.reason = "dll_unavailable:"', source)
        self.assertIn("gameplay must continue unchanged", source.lower())
        self.assertIn("Deliberately drop process-local memory addresses", source)
        self.assertIn("cap = info.cap", source)
        self.assertIn("size = info.size", source)
        self.assertNotIn('battle = info.battle', source)
        self.assertNotIn('manager = info.manager', source)


    def test_full_experimental_profile_is_bound_to_production_initializers(self) -> None:
        features = read("campaigns/main_attila/common/mkmp_features.lua")
        mechanics = read("campaigns/main_attila/mechanics/main.lua")
        common = read("campaigns/main_attila/common/main.lua")
        pope = read("campaigns/main_attila/mechanics/pope/mechanics_pope.lua")
        story = read("campaigns/main_attila/story/main.lua")
        frontend = read("lua_scripts/frontend_mp_campaign.lua")

        self.assertIn('MKMP_FEATURE_PROFILE = "full_experimental_v1";', features)

        expected = {
            "annex_vassals": "experimental_local_ui",
            "buffer_states": "experimental_local_ui",
            "decisions": "experimental_local_ui",
            "hre": "experimental_local_ui",
            "population": "experimental_local_ui",
            "region_trading": "experimental_local_ui",
            "occupation_decisions": "experimental_local_ui",
            "crusades": "experimental_local_ui",
            "pope_ui": "experimental_local_ui",
            "hre_story": "shared_model",
            "sicily_story": "experimental_choice_event",
        }
        for feature, mode in expected.items():
            self.assertRegex(
                features,
                rf'\["{feature}"\]\s*=\s*\{{enabled\s*=\s*true,\s*mode\s*=\s*"{mode}"\}}',
            )

        for feature in (
            "annex_vassals",
            "buffer_states",
            "decisions",
            "hre",
            "population",
            "region_trading",
        ):
            self.assertIn(f'MKMP_FeatureEnabled("{feature}")', mechanics)

        self.assertIn('MKMP_FeatureEnabled("occupation_decisions")', common)
        self.assertIn('MKMP_FeatureEnabled("crusades")', pope)
        self.assertIn('MKMP_FeatureEnabled("pope_ui")', pope)
        self.assertIn('MKMP_FeatureEnabled("hre_story")', story)
        self.assertIn('MKMP_FeatureEnabled("sicily_story")', story)
        self.assertIn("Experimental Full Multiplayer Script Profile", frontend)

    def test_peer_local_modifiers_remain_blocked_in_full_profile(self) -> None:
        features = read("campaigns/main_attila/common/mkmp_features.lua")
        for feature in ("challenges", "ironman", "lucky_nations"):
            self.assertRegex(
                features,
                rf'\["{feature}"\]\s*=\s*\{{enabled\s*=\s*false,\s*mode\s*=\s*"blocked_local_config"\}}',
            )

    def test_old_networking_experiment_remains_disabled(self) -> None:
        source = read("campaigns/main_attila/mk1212_start.lua")
        self.assertIn("--Add_MK1212_Networking_Listeners();", source)
        active = [
            line
            for line in source.splitlines()
            if "Add_MK1212_Networking_Listeners();" in line
            and not line.lstrip().startswith("--")
        ]
        self.assertEqual(active, [])

    def test_output_integrity_rule_is_agent_contract(self) -> None:
        agents = read("AGENTS.md")
        self.assertIn("Output data integrity — treat it like money in the bank", agents)
        self.assertIn("Persistent/output formats MUST have explicit ownership", agents)


if __name__ == "__main__":
    unittest.main(verbosity=2)
