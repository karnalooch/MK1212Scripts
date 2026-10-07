from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class TwdllNativeContracts(unittest.TestCase):
    def test_dllmain_is_loader_lock_minimal(self) -> None:
        main = read("native/twdll/src/main.cpp")
        match = re.search(r"BOOL APIENTRY DllMain\(.*?\n\}", main, re.S)
        self.assertIsNotNone(match)
        body = match.group(0)
        for forbidden in ("Log(", "MH_", "initialize_", "install_campaign_hooks"):
            self.assertNotIn(forbidden, body)
        self.assertIn("DisableThreadLibraryCalls", body)

    def test_lua_abi_is_all_or_nothing(self) -> None:
        main = read("native/twdll/src/main.cpp")
        lua_api = read("native/twdll/src/common/lua_api.cpp")
        lua_sigs = read("native/twdll/src/attila/lua_sigs.cpp")

        entries = re.findall(r'\{"[^"]+",\s*\(void\*\*\)&g_game_[^,]+,', lua_sigs)
        self.assertEqual(len(entries), 23)
        self.assertIn("bool initialize_lua_api()", lua_api)
        self.assertIn("resolved != total", lua_api)
        self.assertIn("if (!initialize_lua_api())", main)
        self.assertIn("initialization aborted because the required Lua ABI is incomplete", main)

    def test_game_signatures_are_capability_degraded(self) -> None:
        game_api = read("native/twdll/src/common/game_api.cpp")
        game_sigs = read("native/twdll/src/attila/game_sigs.cpp")

        entries = re.findall(r'\{"[^"]+",\s*\(void\*\*\)&[^,]+,', game_sigs)
        self.assertEqual(len(entries), 33)
        self.assertIn("*s->target = nullptr", game_api)
        self.assertIn("DEGRADED", game_api)
        self.assertIn("affected features stay unavailable", game_api)

    def test_signature_scanner_fail_closed_contract(self) -> None:
        scanner = read("native/twdll/src/common/signature_scanner.cpp")
        for expected in (
            "signature_bytes.empty() || signature_bytes.size() > size",
            "i <= last_start",
            "uint32_t imm = 0",
            "memcpy(&imm",
            "nlen >= size",
            "if (from_addr <= 1 || max_back == 0)",
        ):
            self.assertIn(expected, scanner)

    def test_hook_enable_failures_have_local_rollback(self) -> None:
        paths = (
            "native/twdll/src/attila/campaign_model.cpp",
            "native/twdll/src/attila/world.cpp",
            "native/twdll/src/attila/campaign_ui.cpp",
            "native/twdll/src/attila/battle_hooks.cpp",
            "native/twdll/src/attila/cai/cai_occupation.cpp",
        )
        rollback_tokens = ("MH_RemoveHook", "uninstall_card_hook", "remove_battle_lifecycle_hooks")

        for relative in paths:
            source = read(relative)
            starts = [m.start() for m in re.finditer(r"MH_EnableHook\(", source)]
            self.assertGreater(len(starts), 0, relative)
            for start in starts:
                window = source[start : start + 900]
                self.assertTrue(
                    any(token in window for token in rollback_tokens),
                    f"{relative}: enable path lacks nearby rollback",
                )

    def test_lua_state_ownership_is_counted(self) -> None:
        main = read("native/twdll/src/main.cpp")
        self.assertIn("g_active_lua_state_count", main)
        self.assertIn("++g_active_lua_state_count", main)
        self.assertIn("g_active_lua_state_count == 0", main)

    def test_api_edge_fixes_remain_fail_closed(self) -> None:
        faction = read("native/twdll/src/attila/faction.cpp")
        region = read("native/twdll/src/attila/region.cpp")
        world = read("native/twdll/src/attila/world.cpp")

        self.assertIn("l_tobool(L, 4)", faction)
        self.assertGreaterEqual(region.count("if (value < 0) value = 0;"), 2)
        self.assertIn("if (!g_load_game)", world)
        self.assertIn("l_pushboolean(L, 0)", world)

    def test_tweaker_raw_bits_and_dual_storage_rollback(self) -> None:
        tweakers = read("native/twdll/src/attila/tweakers.cpp")
        for expected in (
            "bool  has_model",
            "float model_value",
            "bool  has_databases",
            "float databases_value",
            "std::memcpy(&raw_float, &val",
            "value_type != LUA_TBOOLEAN && value_type != LUA_TNUMBER",
        ):
            self.assertIn(expected, tweakers)

    def test_logging_is_bounded_and_fail_soft(self) -> None:
        log_cpp = read("native/twdll/src/common/log.cpp")
        lua_core = read("native/twdll/src/common/lua_core.cpp")

        self.assertIn("8LL * 1024LL * 1024LL", log_cpp)
        self.assertIn("MAX_LOG_LINE_BYTES = 4096", log_cpp)
        self.assertIn("current_size >= MAX_LOG_BYTES", log_cpp)
        self.assertIn("kMaxScriptLogArgs = 64", lua_core)
        self.assertIn("kMaxScriptLogChars = 4096", lua_core)

    def test_host_guard_uses_exact_basename(self) -> None:
        security = read("native/twdll/src/attila/security.cpp")
        self.assertIn('return exe_name == "attila.exe";', security)
        self.assertIn('GetModuleHandleA("empire.retail.dll")', security)

    def test_native_stress_tests_are_wired(self) -> None:
        cmake = read("native/twdll/CMakeLists.txt")
        for target in (
            "twdll_signature_scanner_tests",
            "twdll_log_tests",
            "twdll_security_tests",
        ):
            self.assertIn(target, cmake)
        self.assertIn("TWDLL_WARNINGS_AS_ERRORS", cmake)


if __name__ == "__main__":
    unittest.main()
