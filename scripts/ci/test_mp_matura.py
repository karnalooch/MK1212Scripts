from __future__ import annotations

import random
import re
import unittest

from mp_simulation import (
    CONTRACTS,
    ContractError,
    NativeAdapterProbe,
    Peer,
    RegionTransferQueue,
    SaveCodec,
    Transcript,
    VassalTracker,
    ROOT,
    run_shared_scenario,
)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class MultiplayerMatriculationTest(unittest.TestCase):
    def test_full_experimental_multiplayer_matriculation(self) -> None:
        profile = CONTRACTS["multiplayer_profile"]
        features = profile["features"]

        # 1. Feature matrix: the experimental full profile must be explicit.
        self.assertEqual(profile["name"], "full_experimental_v1")

        newly_unlocked = {
            "annex_vassals": "experimental_local_ui",
            "buffer_states": "experimental_local_ui",
            "decisions": "experimental_local_ui",
            "hre": "experimental_local_ui",
            "population": "experimental_local_ui",
            "region_trading": "experimental_local_ui",
            "occupation_decisions": "experimental_local_ui",
            "religion_conversion_ui": "experimental_local_ui",
            "crusades": "experimental_local_ui",
            "pope_ui": "experimental_local_ui",
            "hre_story": "shared_model",
            "sicily_story": "experimental_choice_event",
        }
        for name, expected_mode in newly_unlocked.items():
            with self.subTest(section="feature_matrix", feature=name):
                self.assertTrue(features[name]["enabled"])
                self.assertEqual(features[name]["mode"], expected_mode)

        blocked = {
            "challenges": "blocked_local_config",
            "ironman": "blocked_local_config",
            "lucky_nations": "blocked_local_config",
            "legacy_networking": "blocked_stale",
            "change_capital": "blocked_external_mutator",
        }
        for name, expected_mode in blocked.items():
            with self.subTest(section="blocked_matrix", feature=name):
                self.assertFalse(features[name]["enabled"])
                self.assertEqual(features[name]["mode"], expected_mode)

        # 2. Bind the matrix to the production Lua unlock points.
        feature_source = read("campaigns/main_attila/common/mkmp_features.lua")
        mechanics_source = read("campaigns/main_attila/mechanics/main.lua")
        common_source = read("campaigns/main_attila/common/main.lua")
        pope_source = read("campaigns/main_attila/mechanics/pope/mechanics_pope.lua")
        story_source = read("campaigns/main_attila/story/main.lua")
        global_ui_source = read("campaigns/main_attila/common/ui/mk1212_global_ui.lua")
        dfn_source = read("campaigns/main_attila/mechanics/mechanics_dynamic_faction_names.lua")
        byz_reconquest_source = read("campaigns/main_attila/byzantium/byzantium_reconquest.lua")
        pope_favour_source = read("campaigns/main_attila/mechanics/pope/mechanics_pope_favour.lua")
        start_source = read("campaigns/main_attila/mk1212_start.lua")
        frontend_source = read("lua_scripts/frontend_mp_campaign.lua")
        runtime_source = read("campaigns/main_attila/common/mkmp_runtime.lua")

        self.assertIn('MKMP_FEATURE_PROFILE = "full_experimental_v1";', feature_source)
        for name, expected_mode in newly_unlocked.items():
            pattern = (
                rf'\["{re.escape(name)}"\]\s*=\s*'
                rf'\{{enabled\s*=\s*true,\s*mode\s*=\s*"{re.escape(expected_mode)}"\}}'
            )
            self.assertRegex(feature_source, pattern)

        for name, expected_mode in blocked.items():
            pattern = (
                rf'\["{re.escape(name)}"\]\s*=\s*'
                rf'\{{enabled\s*=\s*false,\s*mode\s*=\s*"{re.escape(expected_mode)}"\}}'
            )
            self.assertRegex(feature_source, pattern)

        for feature_name in (
            "annex_vassals",
            "buffer_states",
            "decisions",
            "hre",
            "population",
            "region_trading",
        ):
            self.assertIn(
                f'MKMP_FeatureEnabled("{feature_name}")',
                mechanics_source,
            )

        self.assertIn(
            'MKMP_FeatureEnabled("occupation_decisions")',
            common_source,
        )
        self.assertIn('require("common/ui/mk1212_occupation_decisions");', common_source)

        self.assertIn('MKMP_FeatureEnabled("crusades")', pope_source)
        self.assertIn('MKMP_FeatureEnabled("pope_ui")', pope_source)
        self.assertIn('MKMP_FeatureEnabled("hre_story")', story_source)
        self.assertIn('MKMP_FeatureEnabled("sicily_story")', story_source)
        self.assertIn('MKMP_FeatureEnabled("religion_conversion_ui")', global_ui_source)
        self.assertIn('MKMP_FeatureEnabled("decisions")', dfn_source)
        self.assertIn('MKMP_FeatureEnabled("decisions")', byz_reconquest_source)
        self.assertIn('MKMP_FeatureEnabled("decisions")', pope_favour_source)
        self.assertIn('MKMP_FeatureEnabled("change_capital")', start_source)

        self.assertIn(
            "Experimental Full Multiplayer Script Profile",
            frontend_source,
        )
        self.assertIn(
            '"features="..MKMP_FeatureProfileFingerprint()',
            runtime_source,
        )

        active_legacy_networking = [
            line
            for line in start_source.splitlines()
            if "Add_MK1212_Networking_Listeners();" in line
            and not line.lstrip().startswith("--")
        ]
        self.assertEqual(active_legacy_networking, [])

        # 3. Opposite local peer settings may not re-enable blocked modifiers.
        host = Peer(
            name="HOST",
            campaign_seed=1212,
            local_seed=1,
            local_flags={
                "challenges": True,
                "ironman": True,
                "lucky_nations": True,
            },
            hardcoded_slots=True,
        )
        client = Peer(
            name="CLIENT",
            campaign_seed=1212,
            local_seed=999999,
            local_flags={
                "challenges": False,
                "ironman": False,
                "lucky_nations": False,
            },
            hardcoded_slots=False,
        )
        self.assertEqual(host.effective_mp_features(), client.effective_mp_features())
        self.assertEqual(
            host.effective_mp_features(),
            {
                "challenges": False,
                "ironman": False,
                "lucky_nations": False,
            },
        )

        # 4. Randomized two-peer shared mutation transcripts.
        fuzz = random.Random(121212)
        for case in range(200):
            shared_seed = fuzz.randint(0, 2**31 - 1)
            host = Peer(
                "HOST",
                campaign_seed=shared_seed,
                local_seed=fuzz.randint(0, 2**31 - 1),
                local_flags={
                    "challenges": bool(case & 1),
                    "ironman": bool(case & 2),
                    "lucky_nations": bool(case & 4),
                },
                hardcoded_slots=bool(case % 2),
            )
            client = Peer(
                "CLIENT",
                campaign_seed=shared_seed,
                local_seed=fuzz.randint(0, 2**31 - 1),
                local_flags={
                    "challenges": not bool(case & 1),
                    "ironman": not bool(case & 2),
                    "lucky_nations": not bool(case & 4),
                },
                hardcoded_slots=not bool(case % 2),
            )
            run_shared_scenario(host)
            run_shared_scenario(client)
            with self.subTest(section="randomized_peers", case=case):
                host.transcript.assert_matches(client.transcript)

        # 5. RNG bounds must fail before shared mutation.
        bad_token = "common.heir_age:mk_fact_test:1001"
        broken = Peer(
            "BROKEN",
            campaign_seed=1212,
            local_seed=7,
            local_flags={},
            hardcoded_slots=True,
            forced_rng={bad_token: 80},
        )
        with self.assertRaises(ContractError):
            broken.spawn_heir("mk_fact_test", 1001)
        self.assertEqual(broken.transcript.events, [])

        # 6. Persistence matura: randomized insertion order + round-trip.
        codec = SaveCodec()
        save_fuzz = random.Random(20261007)
        for case in range(500):
            keys = [f"k{index:03d}" for index in range(save_fuzz.randint(0, 60))]
            values = {key: save_fuzz.randint(-100000, 100000) for key in keys}
            a_order = keys[:]
            b_order = keys[:]
            save_fuzz.shuffle(a_order)
            save_fuzz.shuffle(b_order)
            a = {key: values[key] for key in a_order}
            b = {key: values[key] for key in b_order}
            with self.subTest(section="save_fuzz", case=case):
                self.assertEqual(codec.key_value(a), codec.key_value(b))

        nested = {
            "master_empty": [],
            "master_a": ["vassal_1", "vassal_2"],
            "master_b": ["vassal_3"],
        }
        payload = codec.nested_lists(nested)
        loaded = codec.load_nested_lists(payload)
        self.assertEqual(payload, codec.nested_lists(loaded))
        self.assertIn("master_empty", loaded)
        self.assertEqual(loaded["master_empty"], [])

        # 7. Vassal correlation must be order-independent and ambiguity-safe.
        host_tracker = VassalTracker()
        client_tracker = VassalTracker()
        host_vassal = Transcript()
        client_vassal = Transcript()

        host_tracker.subjugation("vassal", 20)
        host_tracker.diplomacy("master", "vassal", 20)
        client_tracker.diplomacy("master", "vassal", 20)
        client_tracker.subjugation("vassal", 20)
        host_tracker.process(20, host_vassal)
        client_tracker.process(20, client_vassal)
        host_vassal.assert_matches(client_vassal)

        ambiguous = VassalTracker()
        ambiguous_transcript = Transcript()
        ambiguous.subjugation("vassal", 30)
        ambiguous.diplomacy("master_a", "vassal", 30)
        ambiguous.diplomacy("master_b", "vassal", 30)
        ambiguous.process(30, ambiguous_transcript)
        self.assertEqual(ambiguous_transcript.events, [])
        ambiguous.process(32, ambiguous_transcript)
        self.assertEqual(ambiguous_transcript.events, [])

        # 8. Deferred region transfers: full capacity survives round-trip,
        # then the next unique operation must fail before mutation.
        max_pending = CONTRACTS["region_transfer"]["max_pending"]
        queue = RegionTransferQueue(max_pending=max_pending)
        for index in range(max_pending):
            self.assertTrue(queue.enqueue(f"f{index}", f"r{index}"))
        restored = RegionTransferQueue.load(
            queue.serialize(),
            max_pending=max_pending,
        )
        self.assertEqual(restored.items, queue.items)
        with self.assertRaises(ContractError):
            restored.enqueue("overflow", "overflow_region")
        self.assertEqual(len(restored.items), max_pending)

        # 9. Native observability failure never becomes gameplay authority.
        for mode in (
            "dll_missing",
            "load_failure",
            "capability_missing",
            "native_call_failure",
        ):
            probe = NativeAdapterProbe(mode=mode)
            with self.subTest(section="native_failure", mode=mode):
                self.assertFalse(probe.status()["available"])
                self.assertIsNone(probe.sanitized_battle_telemetry())

        host_native = NativeAdapterProbe(
            mode="ready",
            battle_address="0x11111111",
            manager_address="0x22222222",
            cap=40,
            size=2,
        )
        client_native = NativeAdapterProbe(
            mode="ready",
            battle_address="0xAAAAAAAA",
            manager_address="0xBBBBBBBB",
            cap=40,
            size=2,
        )
        self.assertEqual(
            host_native.sanitized_battle_telemetry(),
            client_native.sanitized_battle_telemetry(),
        )

        # 10. First-divergence detector must fail informatively when state differs.
        good = Transcript()
        bad = Transcript()
        good.record("create_force", faction="test", x=10, y=20)
        bad.record("create_force", faction="test", x=11, y=20)
        divergence = good.first_divergence(bad)
        self.assertIsNotNone(divergence)
        self.assertIn("first divergence", divergence or "")
        self.assertIn("shared mutation #0", divergence or "")

        # Final exam result: reaching here means every repository-level section passed.
        print(
            "MK1212 MP MATRICULATION: PASS "
            f"(profile={profile['name']}, "
            f"randomized_peer_pairs=200, save_fuzz_cases=500)"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
