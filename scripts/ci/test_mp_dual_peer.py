from __future__ import annotations

import random
import unittest

from mp_simulation import (
    CONTRACTS,
    CampaignRng,
    ContractError,
    Mutation,
    NativeAdapterProbe,
    Peer,
    RegionTransferQueue,
    SaveCodec,
    Transcript,
    VassalTracker,
    run_shared_scenario,
)


class DualPeerSimulationTests(unittest.TestCase):
    def test_local_feature_flags_cannot_change_effective_mp_configuration(self) -> None:
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
        self.assertNotEqual(host.environment_fingerprint(), client.environment_fingerprint())

    def test_peer_local_random_seed_does_not_affect_shared_transcript(self) -> None:
        host = Peer(
            "HOST",
            campaign_seed=1212,
            local_seed=1,
            local_flags={},
            hardcoded_slots=True,
        )
        client = Peer(
            "CLIENT",
            campaign_seed=1212,
            local_seed=987654321,
            local_flags={},
            hardcoded_slots=False,
        )

        run_shared_scenario(host)
        run_shared_scenario(client)
        host.transcript.assert_matches(client.transcript)

    def test_rng_contracts_keep_original_gameplay_ranges(self) -> None:
        peer = Peer(
            "HOST",
            campaign_seed=1212,
            local_seed=123,
            local_flags={},
            hardcoded_slots=True,
        )

        age = peer.spawn_heir("mk_fact_test", 1001)
        self.assertGreaterEqual(age, CONTRACTS["rng_contracts"]["heir_age"]["minimum"])
        self.assertLessEqual(age, CONTRACTS["rng_contracts"]["heir_age"]["maximum"])

        new_health = peer.greek_fire("mk_building_test_city", 100)
        damage = 100 - new_health
        self.assertGreaterEqual(
            damage,
            CONTRACTS["rng_contracts"]["greek_fire_damage"]["minimum"],
        )
        self.assertLessEqual(
            damage,
            CONTRACTS["rng_contracts"]["greek_fire_damage"]["maximum"],
        )

        x, y = peer.spawn_invasion_force(
            "mongols",
            "mk_fact_goldenhorde",
            15,
            (400, 420),
            (200, 230),
        )
        self.assertTrue(400 <= x <= 420)
        self.assertTrue(200 <= y <= 230)

    def test_out_of_range_campaign_rng_fails_before_shared_mutation(self) -> None:
        token = "common.heir_age:mk_fact_test:1001"
        peer = Peer(
            "HOST",
            campaign_seed=1212,
            local_seed=1,
            local_flags={},
            hardcoded_slots=True,
            forced_rng={token: 80},
        )

        with self.assertRaisesRegex(ContractError, "escaped bounds before mutation"):
            peer.spawn_heir("mk_fact_test", 1001)

        self.assertEqual(peer.transcript.events, [])

    def test_invalid_rng_bounds_fail_closed(self) -> None:
        rng = CampaignRng(1212)
        with self.assertRaisesRegex(ContractError, "invalid RNG bounds"):
            rng.randint(30, 16, "bad")

    def test_transcript_reports_first_divergence(self) -> None:
        host = Transcript()
        client = Transcript()
        host.record("treasury_mod", faction="A", amount=2500)
        client.record("treasury_mod", faction="A", amount=2500)
        host.record("create_force", faction="B", x=10, y=20)
        client.record("create_force", faction="B", x=11, y=20)

        divergence = host.first_divergence(client)
        self.assertIsNotNone(divergence)
        self.assertIn("shared mutation #1", divergence or "")
        self.assertIn("x', 10", divergence or "")
        self.assertIn("x', 11", divergence or "")

    def test_vassal_subjugation_is_independent_of_event_arrival_order(self) -> None:
        host_tracker = VassalTracker()
        client_tracker = VassalTracker()
        host = Transcript()
        client = Transcript()

        host_tracker.subjugation("vassal", turn=20)
        host_tracker.diplomacy("master", "vassal", turn=20)

        client_tracker.diplomacy("master", "vassal", turn=20)
        client_tracker.subjugation("vassal", turn=20)

        host_tracker.process(20, host)
        client_tracker.process(20, client)

        host.assert_matches(client)
        self.assertEqual(
            host.events,
            [
                Mutation(
                    kind="FactionVassalized",
                    payload=(("master", "master"), ("vassal", "vassal")),
                )
            ],
        )

    def test_vassal_ambiguous_correlation_never_guesses(self) -> None:
        tracker = VassalTracker()
        transcript = Transcript()

        tracker.subjugation("vassal", turn=20)
        tracker.diplomacy("master_a", "vassal", turn=20)
        tracker.diplomacy("master_b", "vassal", turn=20)
        tracker.process(20, transcript)

        self.assertEqual(transcript.events, [])
        self.assertIn("vassal", tracker.pending_subjugations)

        tracker.process(22, transcript)
        self.assertEqual(transcript.events, [])
        self.assertEqual(tracker.pending_subjugations, {})
        self.assertEqual(tracker.pending_diplomacy, {})

    def test_liberation_alliance_does_not_become_vassalization(self) -> None:
        tracker = VassalTracker()
        transcript = Transcript()
        tracker.set_allied("master", "released")
        tracker.liberation("master", "released", 10)
        tracker.process(10, transcript)
        self.assertEqual(transcript.events, [])

    def test_region_transfer_queue_deduplicates_and_survives_roundtrip(self) -> None:
        queue = RegionTransferQueue(max_pending=4)
        self.assertTrue(queue.enqueue("faction_a", "region_a"))
        self.assertFalse(queue.enqueue("faction_a", "region_a"))
        self.assertTrue(queue.enqueue("faction_b", "region_b"))

        encoded = queue.serialize()
        restored = RegionTransferQueue.load(encoded, max_pending=4)
        self.assertEqual(restored.items, queue.items)

    def test_region_transfer_queue_fails_before_overflow(self) -> None:
        queue = RegionTransferQueue(max_pending=2)
        queue.enqueue("a", "ra")
        queue.enqueue("b", "rb")
        with self.assertRaisesRegex(ContractError, "queue full"):
            queue.enqueue("c", "rc")
        self.assertEqual(queue.items, [("a", "ra"), ("b", "rb")])

    def test_save_serialization_is_canonical_under_fuzzed_insertion_order(self) -> None:
        codec = SaveCodec()
        fuzz = random.Random(1212)

        for case in range(300):
            keys = [f"k{index:03d}" for index in range(fuzz.randint(0, 40))]
            values = {key: fuzz.randint(-5000, 5000) for key in keys}

            order_a = keys[:]
            order_b = keys[:]
            fuzz.shuffle(order_a)
            fuzz.shuffle(order_b)
            a = {key: values[key] for key in order_a}
            b = {key: values[key] for key in order_b}

            with self.subTest(case=case, shape="key_value"):
                self.assertEqual(codec.key_value(a), codec.key_value(b))

            bool_values = {key: bool(values[key] % 2) for key in keys}
            a_bool = {key: bool_values[key] for key in order_a}
            b_bool = {key: bool_values[key] for key in order_b}
            with self.subTest(case=case, shape="boolean_map"):
                self.assertEqual(codec.boolean_map(a_bool), codec.boolean_map(b_bool))

    def test_save_load_save_is_stable_and_preserves_explicit_empty_nested_lists(self) -> None:
        codec = SaveCodec()
        source = {
            "faction_c": ["v3", "v4"],
            "faction_a": [],
            "faction_b": ["v1"],
        }
        payload = codec.nested_lists(source)
        loaded = codec.load_nested_lists(payload)
        second = codec.nested_lists(loaded)

        self.assertEqual(payload, second)
        self.assertIn("faction_a", loaded)
        self.assertEqual(loaded["faction_a"], [])

    def test_nickname_stats_are_canonical(self) -> None:
        codec = SaveCodec()
        a = {
            "22": {
                "regions_taken": 2,
                "captives_killed": 3,
                "times_excommunicated": 0,
                "turns_without_revolt": 5,
                "heroic_victories": 1,
            },
            "11": {
                "regions_taken": 8,
                "captives_killed": 0,
                "times_excommunicated": 1,
                "turns_without_revolt": 2,
                "heroic_victories": 4,
            },
        }
        b = {"11": a["11"], "22": a["22"]}
        self.assertEqual(codec.nickname_stats(a), codec.nickname_stats(b))
        self.assertTrue(codec.nickname_stats(a).startswith("11,"))

    def test_save_budget_failure_is_atomic(self) -> None:
        codec = SaveCodec(max_entries=1, max_bytes=10)
        storage = {"safe": "old"}

        with self.assertRaisesRegex(ContractError, "entries=2"):
            codec.atomic_write(storage, "safe", "a,1,;b,2,;", entries=2)
        self.assertEqual(storage, {"safe": "old"})

        with self.assertRaisesRegex(ContractError, "bytes="):
            codec.atomic_write(storage, "safe", "01234567890", entries=1)
        self.assertEqual(storage, {"safe": "old"})

    def test_native_adapter_bootstraps_in_singleplayer_and_multiplayer(self) -> None:
        for multiplayer in (False, True):
            probe = NativeAdapterProbe(mode="ready")

            with self.subTest(multiplayer=multiplayer):
                self.assertTrue(probe.initialize(multiplayer=multiplayer))
                self.assertTrue(probe.status()["available"])
                self.assertEqual(probe.status()["reason"], "ready")
                self.assertEqual(probe.luaopen_calls, 1)
                self.assertEqual(probe.multiplayer, multiplayer)

    def test_native_adapter_initialization_is_idempotent_per_lua_state(self) -> None:
        probe = NativeAdapterProbe(mode="ready")

        self.assertTrue(probe.initialize(multiplayer=False))
        self.assertTrue(probe.initialize(multiplayer=False))

        self.assertEqual(probe.initialize_calls, 2)
        self.assertEqual(probe.luaopen_calls, 1)
        self.assertTrue(probe.status()["available"])

    def test_native_adapter_identity_mismatch_fails_closed(self) -> None:
        bad_game = NativeAdapterProbe(mode="ready", game_build="Rome2")
        bad_sha = NativeAdapterProbe(mode="ready", twdll_sha="unknown")

        self.assertFalse(bad_game.initialize(multiplayer=False))
        self.assertFalse(bad_sha.initialize(multiplayer=True))
        self.assertFalse(bad_game.status()["available"])
        self.assertFalse(bad_sha.status()["available"])
        self.assertIn("game_build_mismatch", bad_game.status()["reason"])
        self.assertIn("invalid_build_sha", bad_sha.status()["reason"])
        self.assertIsNone(bad_game.sanitized_battle_telemetry())
        self.assertIsNone(bad_sha.sanitized_battle_telemetry())

    def test_native_adapter_failures_never_change_shared_gameplay_transcript(self) -> None:
        modes = (
            "dll_missing",
            "load_failure",
            "capability_missing",
            "native_call_failure",
        )
        baseline = Transcript()

        for mode in modes:
            probe = NativeAdapterProbe(mode=mode)
            with self.subTest(mode=mode):
                self.assertFalse(probe.status()["available"])
                self.assertIsNone(probe.sanitized_battle_telemetry())
                baseline.assert_matches(Transcript())

    def test_process_local_native_addresses_are_filtered(self) -> None:
        host = NativeAdapterProbe(
            mode="ready",
            battle_address="0x11111111",
            manager_address="0x22222222",
            cap=40,
            size=2,
        )
        client = NativeAdapterProbe(
            mode="ready",
            battle_address="0xAAAAAAAA",
            manager_address="0xBBBBBBBB",
            cap=40,
            size=2,
        )
        self.assertEqual(
            host.sanitized_battle_telemetry(),
            client.sanitized_battle_telemetry(),
        )
        self.assertNotIn("battle_address", host.sanitized_battle_telemetry() or {})
        self.assertNotIn("manager_address", host.sanitized_battle_telemetry() or {})

    def test_randomized_dual_peer_scenarios_keep_shared_transcript_equal(self) -> None:
        fuzz = random.Random(424242)

        for case in range(100):
            shared_seed = fuzz.randint(0, 2**31 - 1)
            host = Peer(
                "HOST",
                campaign_seed=shared_seed,
                local_seed=fuzz.randint(0, 2**31 - 1),
                local_flags={"ironman": True, "lucky_nations": False},
                hardcoded_slots=bool(case % 2),
            )
            client = Peer(
                "CLIENT",
                campaign_seed=shared_seed,
                local_seed=fuzz.randint(0, 2**31 - 1),
                local_flags={"ironman": False, "lucky_nations": True},
                hardcoded_slots=not bool(case % 2),
            )

            run_shared_scenario(host)
            run_shared_scenario(client)

            with self.subTest(case=case):
                host.transcript.assert_matches(client.transcript)


if __name__ == "__main__":
    unittest.main(verbosity=2)
