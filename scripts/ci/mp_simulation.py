from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
import json
import random

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = json.loads((Path(__file__).with_name("mp_contracts.json")).read_text(encoding="utf-8"))


class ContractError(RuntimeError):
    pass


def _freeze(value: Any) -> Any:
    if isinstance(value, dict):
        return tuple((str(key), _freeze(value[key])) for key in sorted(value, key=lambda item: str(item)))
    if isinstance(value, (list, tuple)):
        return tuple(_freeze(item) for item in value)
    if isinstance(value, set):
        return tuple(sorted(_freeze(item) for item in value))
    return value


@dataclass(frozen=True)
class Mutation:
    kind: str
    payload: tuple[tuple[str, Any], ...]


@dataclass
class Transcript:
    events: list[Mutation] = field(default_factory=list)

    def record(self, kind: str, **payload: Any) -> None:
        frozen = tuple((key, _freeze(payload[key])) for key in sorted(payload))
        self.events.append(Mutation(kind=kind, payload=frozen))

    def first_divergence(self, other: "Transcript") -> str | None:
        shared = min(len(self.events), len(other.events))
        for index in range(shared):
            if self.events[index] != other.events[index]:
                return (
                    f"first divergence at shared mutation #{index}: "
                    f"HOST={self.events[index]!r} CLIENT={other.events[index]!r}"
                )
        if len(self.events) != len(other.events):
            return (
                f"first divergence at shared mutation #{shared}: "
                f"HOST length={len(self.events)} CLIENT length={len(other.events)}"
            )
        return None

    def assert_matches(self, other: "Transcript") -> None:
        divergence = self.first_divergence(other)
        if divergence:
            raise ContractError(divergence)


class CampaignRng:
    def __init__(self, seed: int, forced: dict[str, int] | None = None) -> None:
        self._rng = random.Random(seed)
        self._forced = dict(forced or {})
        self.draws: list[tuple[str, int, int, int]] = []

    def randint(self, minimum: int, maximum: int, token: str) -> int:
        if minimum > maximum:
            raise ContractError(f"invalid RNG bounds for {token}: {minimum}..{maximum}")
        result = self._forced.get(token)
        if result is None:
            result = self._rng.randint(minimum, maximum)
        if not minimum <= result <= maximum:
            raise ContractError(
                f"campaign RNG escaped bounds before mutation: token={token} "
                f"range={minimum}..{maximum} result={result}"
            )
        self.draws.append((token, minimum, maximum, result))
        return result


@dataclass
class Peer:
    name: str
    campaign_seed: int
    local_seed: int
    local_flags: dict[str, bool]
    hardcoded_slots: bool
    forced_rng: dict[str, int] | None = None
    transcript: Transcript = field(default_factory=Transcript)

    def __post_init__(self) -> None:
        self.local_rng = random.Random(self.local_seed)
        self.campaign_rng = CampaignRng(self.campaign_seed, self.forced_rng)

    def effective_mp_features(self) -> dict[str, bool]:
        # Campaign runtime is authoritative; local frontend/SVR values are tainted input.
        policy = CONTRACTS["multiplayer_effective_features"]
        return {key: bool(policy[key]) for key in sorted(policy)}

    def environment_fingerprint(self) -> str:
        return f"slots10={1 if self.hardcoded_slots else 0}"

    def spawn_heir(self, faction: str, leader_cqi: int) -> int:
        cfg = CONTRACTS["rng_contracts"]["heir_age"]
        token = f"common.heir_age:{faction}:{leader_cqi}"
        age = self.campaign_rng.randint(cfg["minimum"], cfg["maximum"], token)
        self.transcript.record(
            "spawn_character_into_family_tree",
            faction=faction,
            leader_cqi=leader_cqi,
            age=age,
            make_heir=True,
        )
        return age

    def greek_fire(self, building: str, old_health: int) -> int:
        cfg = CONTRACTS["rng_contracts"]["greek_fire_damage"]
        token = f"greek_fire.damage:{building}"
        damage = self.campaign_rng.randint(cfg["minimum"], cfg["maximum"], token)
        new_health = max(0, old_health - damage)
        self.transcript.record(
            "instant_set_building_health_percent",
            building=building,
            old_health=old_health,
            damage=damage,
            new_health=new_health,
        )
        return new_health

    def spawn_invasion_force(
        self,
        feature: str,
        faction: str,
        turn: int,
        x_bounds: tuple[int, int],
        y_bounds: tuple[int, int],
    ) -> tuple[int, int]:
        x = self.campaign_rng.randint(
            x_bounds[0],
            x_bounds[1],
            f"{feature}.spawn_x:{faction}:{turn}",
        )
        y = self.campaign_rng.randint(
            y_bounds[0],
            y_bounds[1],
            f"{feature}.spawn_y:{faction}:{turn}",
        )
        force_id = f"{faction}{x}{y}{turn}"
        self.transcript.record(
            "create_force",
            feature=feature,
            faction=faction,
            turn=turn,
            x=x,
            y=y,
            force_id=force_id,
        )
        return x, y


class VassalTracker:
    def __init__(self, max_age_turns: int | None = None) -> None:
        self.max_age_turns = (
            CONTRACTS["vassal_tracking"]["max_pending_age_turns"]
            if max_age_turns is None
            else max_age_turns
        )
        self.pending_liberations: dict[str, int] = {}
        self.pending_subjugations: dict[str, int] = {}
        self.pending_diplomacy: dict[str, int] = {}
        self.alliances: set[tuple[str, str]] = set()
        self.vassals: dict[str, set[str]] = {}

    @staticmethod
    def _pair(first: str, second: str) -> str:
        return f"{first}|{second}"

    @staticmethod
    def _split(token: str) -> tuple[str, str]:
        first, second = token.split("|", 1)
        return first, second

    def liberation(self, master: str, vassal: str, turn: int) -> None:
        self.pending_liberations[self._pair(master, vassal)] = turn

    def subjugation(self, vassal: str, turn: int) -> None:
        self.pending_subjugations[vassal] = turn

    def diplomacy(self, proposer: str, recipient: str, turn: int) -> None:
        self.pending_diplomacy[self._pair(proposer, recipient)] = turn

    def set_allied(self, first: str, second: str) -> None:
        self.alliances.add(tuple(sorted((first, second))))

    def _is_allied(self, first: str, second: str) -> bool:
        return tuple(sorted((first, second))) in self.alliances

    def _record_vassal(self, master: str, vassal: str, transcript: Transcript) -> None:
        current = self.vassals.setdefault(master, set())
        if vassal in current:
            return
        current.add(vassal)
        transcript.record("FactionVassalized", master=master, vassal=vassal)

    def process(self, current_turn: int, transcript: Transcript) -> None:
        for token in sorted(tuple(self.pending_liberations)):
            queued_turn = self.pending_liberations[token]
            master, vassal = self._split(token)
            if self._is_allied(master, vassal):
                self.pending_liberations.pop(token, None)
                continue
            self._record_vassal(master, vassal, transcript)
            self.pending_liberations.pop(token, None)

        for vassal in sorted(tuple(self.pending_subjugations)):
            subjugation_turn = self.pending_subjugations[vassal]
            matches: list[tuple[str, str]] = []
            for token in sorted(self.pending_diplomacy):
                proposer, recipient = self._split(token)
                if recipient == vassal and self.pending_diplomacy[token] == subjugation_turn:
                    matches.append((token, proposer))

            if len(matches) == 1:
                token, proposer = matches[0]
                self._record_vassal(proposer, vassal, transcript)
                self.pending_diplomacy.pop(token, None)
                self.pending_subjugations.pop(vassal, None)
            elif len(matches) == 0 and current_turn - subjugation_turn > self.max_age_turns:
                self.pending_subjugations.pop(vassal, None)
            # Ambiguous correlation deliberately remains pending until bounded expiry.

        for token in sorted(tuple(self.pending_diplomacy)):
            if current_turn - self.pending_diplomacy[token] > self.max_age_turns:
                self.pending_diplomacy.pop(token, None)

        for vassal in sorted(tuple(self.pending_subjugations)):
            if current_turn - self.pending_subjugations[vassal] > self.max_age_turns:
                self.pending_subjugations.pop(vassal, None)


class SaveCodec:
    def __init__(
        self,
        max_entries: int | None = None,
        max_bytes: int | None = None,
    ) -> None:
        limits = CONTRACTS["save_limits"]
        self.max_entries = limits["max_entries"] if max_entries is None else max_entries
        self.max_bytes = limits["max_string_bytes"] if max_bytes is None else max_bytes

    def _validate(self, payload: str, entries: int) -> str:
        if entries > self.max_entries:
            raise ContractError(
                f"save refused before write: entries={entries} max={self.max_entries}"
            )
        if len(payload.encode("utf-8")) > self.max_bytes:
            raise ContractError(
                f"save refused before write: bytes={len(payload.encode('utf-8'))} "
                f"max={self.max_bytes}"
            )
        return payload

    @staticmethod
    def _keys(table: dict[Any, Any]) -> list[Any]:
        return sorted(table, key=lambda item: str(item))

    def key_value(self, table: dict[Any, Any]) -> str:
        payload = "".join(
            f"{key},{table[key]},;" for key in self._keys(table)
        )
        return self._validate(payload, len(table))

    def boolean_map(self, table: dict[Any, bool]) -> str:
        payload = "".join(
            f"{key},{str(bool(table[key])).lower()},;" for key in self._keys(table)
        )
        return self._validate(payload, len(table))

    def nested_lists(self, table: dict[Any, list[Any]]) -> str:
        chunks: list[str] = []
        for key in self._keys(table):
            values = table[key]
            chunks.append(f"{key}," + "".join(f"{value}," for value in values) + ";")
        return self._validate("".join(chunks), len(table))

    def nickname_stats(self, table: dict[Any, dict[str, int]]) -> str:
        order = (
            "regions_taken",
            "captives_killed",
            "times_excommunicated",
            "turns_without_revolt",
            "heroic_victories",
        )
        chunks: list[str] = []
        for key in self._keys(table):
            row = table[key]
            chunks.append(
                f"{key}," + "".join(f"{row[field]}," for field in order) + ";"
            )
        return self._validate("".join(chunks), len(table))

    @staticmethod
    def load_key_value(payload: str) -> dict[str, str]:
        result: dict[str, str] = {}
        for record in payload.split(";"):
            if not record:
                continue
            parts = [part for part in record.split(",") if part != ""]
            if len(parts) >= 2:
                result[parts[0]] = parts[1]
        return result

    @staticmethod
    def load_nested_lists(payload: str) -> dict[str, list[str]]:
        result: dict[str, list[str]] = {}
        for record in payload.split(";"):
            if not record:
                continue
            parts = record.split(",")
            key = parts[0]
            values = [part for part in parts[1:] if part != ""]
            result[key] = values
        return result

    def atomic_write(
        self,
        storage: dict[str, str],
        key: str,
        payload: str,
        entries: int,
    ) -> None:
        validated = self._validate(payload, entries)
        storage[key] = validated


class RegionTransferQueue:
    def __init__(self, max_pending: int | None = None) -> None:
        self.max_pending = (
            CONTRACTS["region_transfer"]["max_pending"]
            if max_pending is None
            else max_pending
        )
        self.items: list[tuple[str, str]] = []

    def enqueue(self, faction: str, region: str) -> bool:
        record = (faction, region)
        if record in self.items:
            return False
        if len(self.items) >= self.max_pending:
            raise ContractError(f"region transfer queue full: max={self.max_pending}")
        self.items.append(record)
        return True

    def serialize(self) -> list[str]:
        return [f"{faction}|{region}" for faction, region in self.items]

    @classmethod
    def load(
        cls,
        encoded: list[str],
        max_pending: int | None = None,
    ) -> "RegionTransferQueue":
        queue = cls(max_pending=max_pending)
        for token in encoded:
            if "|" not in token:
                continue
            faction, region = token.split("|", 1)
            if faction and region:
                queue.enqueue(faction, region)
        return queue


@dataclass
class NativeAdapterProbe:
    mode: str
    battle_address: str = "0x00000000"
    manager_address: str = "0x00000000"
    cap: int | None = 40
    size: int | None = 0
    game_build: str = "Attila"
    twdll_sha: str = "7c6f5b6d691313f128e9212e37c87c2292e79504"
    initialized: bool = False
    available: bool = False
    runtime_reason: str = "not_initialized"
    initialize_calls: int = 0
    luaopen_calls: int = 0
    multiplayer: bool | None = None

    def initialize(self, *, multiplayer: bool) -> bool:
        self.initialize_calls += 1
        self.multiplayer = multiplayer

        if self.initialized:
            return self.available

        self.initialized = True

        if self.mode != "ready":
            self.runtime_reason = self.mode
            self.available = False
            return False

        self.luaopen_calls += 1

        if self.game_build != "Attila":
            self.runtime_reason = f"game_build_mismatch:{self.game_build}"
            self.available = False
            return False

        if len(self.twdll_sha) != 40:
            self.runtime_reason = f"invalid_build_sha:{self.twdll_sha}"
            self.available = False
            return False

        self.runtime_reason = "ready"
        self.available = True
        return True

    def status(self) -> dict[str, Any]:
        if self.initialized:
            return {
                "available": self.available,
                "reason": self.runtime_reason,
                "initialize_calls": self.initialize_calls,
                "luaopen_calls": self.luaopen_calls,
                "multiplayer": self.multiplayer,
            }

        if self.mode != "ready":
            return {
                "available": False,
                "reason": self.mode,
            }

        return {
            "available": True,
            "reason": "ready",
        }

    def sanitized_battle_telemetry(self) -> dict[str, int | None] | None:
        if self.initialized and not self.available:
            return None
        if not self.initialized and self.mode != "ready":
            return None
        return {
            "cap": self.cap,
            "size": self.size,
        }


def run_shared_scenario(peer: Peer) -> Transcript:
    peer.spawn_heir("mk_fact_test", 1001)
    peer.greek_fire("mk_building_test_city", 100)
    peer.spawn_invasion_force(
        "mongols",
        "mk_fact_goldenhorde",
        15,
        (400, 420),
        (200, 230),
    )
    peer.spawn_invasion_force(
        "timurids",
        "mk_fact_timurids",
        337,
        (500, 530),
        (300, 340),
    )
    return peer.transcript
