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
        }
        registry = source("mkmp_sp_parity.lua")
        for path, features in mapping.items():
            with self.subTest(file=path):
                content = source(path)
                for feature in features:
                    self.assertIn(f'MKMP_SP_Parity_Enabled("{feature}")', content)
                    self.assertIn(f"{feature} = false", registry)

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
