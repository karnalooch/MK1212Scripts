"""Source-level fail-closed MP parity tests; NOT 2-PC runtime proof."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "campaigns/main_attila"


def source(path: str) -> str:
    return (LUA / path).read_text(encoding="utf-8")


class MPParityGatesTests(unittest.TestCase):
    def test_default_mp_unchanged(self):
        config = source("mkmp_sp_parity.lua")
        self.assertIn("enabled = false", config)
        self.assertIn("MKMP_SP_PARITY.enabled ~= true", config)
        self.assertIn("not cm:is_multiplayer()", config)
        self.assertIn("MKMP_SP_PARITY[feature] == true", config)

    def test_loaded_before_campaign_modules(self):
        scripting = source("scripting.lua")
        self.assertLess(
            scripting.index('require("mkmp_sp_parity")'),
            scripting.index('require("common/main")'),
        )
        self.assertLess(
            scripting.index('require("mkmp_sp_parity")'),
            scripting.index('require("mechanics/main")'),
        )

    def test_all_wired_experimental_entrypoints(self):
        mapping = {
            "mechanics/main.lua": (
                "annex_vassals", "buffer_states", "decisions", "hre",
                "population", "region_trading",
            ),
            "common/main.lua": ("occupation_decisions",),
            "story/main.lua": ("story_hre_sicily",),
            "luckynations/main.lua": ("lucky_nations",),
            "challenges/main.lua": (
                "challenge_judgement_day", "challenge_no_retreat",
                "challenge_this_is_total_war",
            ),
            "mechanics/pope/mechanics_pope.lua": (
                "pope_crusades_ui", "pope_capital_visibility",
            ),
            "mechanics/pope/mechanics_pope_favour.lua": (
                "pope_favour_decisions",
            ),
            "common/ui/mk1212_global_ui.lua": (
                "global_ui_religion_change",
            ),
            "byzantium/byzantium_reconquest.lua": ("kingdom_decisions",),
            "mechanics/mechanics_dynamic_faction_names.lua": (
                "dynamic_faction_decisions",
            ),
            "kingdoms/kingdom_armenia.lua": ("kingdom_decisions",),
            "kingdoms/kingdom_byzantium.lua": ("kingdom_decisions",),
            "kingdoms/kingdom_golden_horde.lua": ("kingdom_decisions",),
            "kingdoms/kingdom_ilkhanate.lua": ("kingdom_decisions",),
            "kingdoms/kingdom_italy.lua": ("kingdom_decisions",),
            "kingdoms/kingdom_persia.lua": ("kingdom_decisions",),
            "kingdoms/kingdom_poland.lua": ("kingdom_decisions",),
            "kingdoms/kingdom_serbia.lua": ("kingdom_decisions",),
            "kingdoms/kingdom_spain.lua": ("kingdom_decisions",),
        }
        registry = source("mkmp_sp_parity.lua")
        for path, features in mapping.items():
            with self.subTest(file=path):
                content = source(path)
                for feature in features:
                    self.assertIn(f'MKMP_SP_Parity_Enabled("{feature}")', content)
                    self.assertIn(f"{feature} = false", registry)

    def test_all_experimental_still_requires_explicit_opt_in(self):
        config = source("mkmp_sp_parity.lua")
        self.assertIn("enabled = false", config)
        self.assertIn("all_experimental = false", config)
        self.assertIn("MKMP_SP_PARITY.enabled ~= true", config)
        self.assertIn('feature == "all_experimental"', config)
        self.assertIn('type(MKMP_SP_PARITY[feature]) ~= "boolean"', config)
        self.assertIn('MKMP_SP_PARITY.decisions == true', config)

    def test_manual_kingdom_gate_disables_automatic_mp_branch(self):
        paths = (
            "byzantium/byzantium_reconquest.lua",
            "kingdoms/kingdom_armenia.lua",
            "kingdoms/kingdom_byzantium.lua",
            "kingdoms/kingdom_golden_horde.lua",
            "kingdoms/kingdom_ilkhanate.lua",
            "kingdoms/kingdom_italy.lua",
            "kingdoms/kingdom_persia.lua",
            "kingdoms/kingdom_poland.lua",
            "kingdoms/kingdom_spain.lua",
        )
        for path in paths:
            with self.subTest(path=path):
                self.assertIn(
                    '(cm:is_multiplayer() and not MKMP_SP_Parity_Enabled("kingdom_decisions")) or',
                    source(path),
                )

    def test_manual_dynamic_faction_gate_disables_automatic_mp_branch(self):
        names = source("mechanics/mechanics_dynamic_faction_names.lua")
        self.assertIn(
            '(cm:is_multiplayer() and not MKMP_SP_Parity_Enabled("dynamic_faction_decisions"))',
            names,
        )

    def test_sp_frontend_not_loaded_as_mp_authority(self):
        lucky = source("luckynations/lucky_nations.lua")
        self.assertIn(
            'LUCKY_NATIONS_ENABLED = MKMP_SP_Parity_Enabled("lucky_nations")',
            lucky,
        )
        self.assertIn("elseif cm:is_new_game() then", lucky)
        challenges = source("challenges/main.lua")
        self.assertIn("elseif cm:is_new_game() then", challenges)

    def test_high_risk_systems_still_blocked(self):
        config = source("mkmp_sp_parity.lua")
        for key in ("ironman", "change_capital", "legacy_networking"):
            self.assertIn(f"{key} = true", config)
        self.assertIn(
            "if cm:is_multiplayer() then",
            source("ironman/main.lua"),
        )
        self.assertIn(
            "if cm:is_multiplayer() then",
            source("mk1212_start.lua"),
        )
        self.assertIn(
            "--Add_MK1212_Networking_Listeners()",
            source("mk1212_start.lua"),
        )

    def test_read_only_candidate_inventory(self):
        from audit_sp_mp_gates import inventory
        records = inventory(ROOT)
        self.assertTrue(any(r["path"].endswith("mechanics/main.lua") for r in records))
        self.assertTrue(any(r["path"].endswith("common/main.lua") for r in records))


if __name__ == "__main__":
    unittest.main()
