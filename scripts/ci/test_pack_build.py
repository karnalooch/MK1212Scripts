"""Packaging regressions: actual Git blobs, an independent PFH4 reader and Lua 5.1.

These tests cannot prove that Attila loads the selected pack or synchronizes MP.
"""
from __future__ import annotations

import copy
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/pack"))

import build_mk1212_pack as pack
from lua_test_runtime import run_lua_fixture


def independent_pfh4_read(raw: bytes) -> tuple[dict[str, bytes], int]:
    """Test reader deliberately shares no parser/encoder helper with production.

    Consume the RPFM-documented 28-byte header, a separate index stream, then
    sequential payloads; every section must end at its declared boundary.
    """
    stream = io.BytesIO(raw)
    assert stream.read(4) == b"PFH4"
    header = [int.from_bytes(stream.read(4), "little") for _ in range(6)]
    kind, dependency_count, dependency_size, file_count, index_size, timestamp = header
    assert kind == 3 and dependency_count == 0 and dependency_size == 0
    index = io.BytesIO(stream.read(index_size))
    rows = []
    for _ in range(file_count):
        size_bytes = index.read(4)
        assert len(size_bytes) == 4
        path_bytes = bytearray()
        while True:
            char = index.read(1)
            assert char
            if char == b"\0":
                break
            path_bytes.extend(char)
        assert b"/" not in path_bytes
        rows.append((path_bytes.decode("ascii").replace("\\", "/"),
                     int.from_bytes(size_bytes, "little")))
    assert index.tell() == index_size and index.read() == b""
    result = {}
    for path, size in rows:
        assert path.casefold() not in {p.casefold() for p in result}
        data = stream.read(size)
        assert len(data) == size
        result[path] = data
    assert stream.read() == b""
    return result, timestamp


class PackBinaryTests(unittest.TestCase):
    def test_minimal_archive_matches_handwritten_golden_bytes(self):
        # A twelve-byte path, NUL, uint32 size = 17-byte index; nine data bytes.
        expected = bytes.fromhex(
            "50464834 03000000 00000000 00000000 01000000 11000000 00000000 09000000"
        ) + b"script\\a.lua\0return 1\n"
        actual = pack.encode_pfh4({"script/a.lua": b"return 1\n"})
        self.assertEqual(actual, expected)
        self.assertEqual(independent_pfh4_read(actual), ({"script/a.lua": b"return 1\n"}, 0))

    def test_existing_native_attila_fixture_roundtrips_byte_for_byte(self):
        raw = (ROOT / "native/twdll/tests/attila/extra.pack").read_bytes()
        files, timestamp = independent_pfh4_read(raw)
        self.assertEqual(len(files), 4)
        self.assertIn("db/commander_unit_permissions_tables/@___commander_unit_permissions", files)
        # The fixture contains an '@' path outside the deliberately narrower
        # shipping-Lua contract. Inspect its header/index independently; rebuild
        # its generic bytes without weakening shipping path validation.
        rows = sorted(files.items(), key=lambda row: row[0].replace("/", "\\").lower())
        index = b"".join(struct.pack("<I", len(data)) + path.replace("/", "\\").encode() + b"\0"
                         for path, data in rows)
        rebuilt = struct.pack("<4s6I", b"PFH4", 3, 0, 0, 4, len(index), timestamp)
        rebuilt += index + b"".join(data for _, data in rows)
        self.assertEqual(rebuilt, raw)

    def test_deterministic_index_order_with_nested_paths(self):
        files = {"script/Z.lua": b"z", "script/a/b.lua": b"b", "script/a.lua": b"a"}
        first = pack.encode_pfh4(files)
        second = pack.encode_pfh4(dict(reversed(list(files.items()))))
        self.assertEqual(first, second)
        decoded, _ = independent_pfh4_read(first)
        self.assertEqual(list(decoded), ["script/a.lua", "script/a/b.lua", "script/Z.lua"])

    def test_unsafe_duplicate_and_nonregular_paths_fail_closed(self):
        for path in ("../a.lua", "/a.lua", "script/../a.lua", "script//a.lua",
                     "script\\a.lua", "script/a\x00.lua", "script/a;evil.lua"):
            with self.subTest(path=path), self.assertRaises(pack.PackError):
                pack.encode_pfh4({path: b"x"})
        with self.assertRaises(pack.PackError):
            pack.encode_pfh4({"script/a.lua": b"a", "script/A.lua": b"b"})

    def test_truncated_overlong_duplicate_and_incompatible_archives_are_rejected(self):
        raw = pack.encode_pfh4({"script/a.lua": b"a", "script/b.lua": b"b"})
        corruptions = [raw[:27], raw[:-1], raw + b"extra",
                       raw.replace(b"script\\b.lua", b"script\\a.lua")]
        movie = bytearray(raw)
        movie[4:8] = (4).to_bytes(4, "little")
        corruptions.append(bytes(movie))
        for data in corruptions:
            with self.subTest(size=len(data)), self.assertRaises(pack.PackError):
                pack.read_pfh4(data)


class PackGitTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="mk1212-pack-test-")
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name) / "repo"
        self.repo.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.name", "Pack test")
        self.git("config", "user.email", "pack-test@example.invalid")
        self.sources = {
            pack.REGISTRY: pack.git(ROOT, "show", f"HEAD:{pack.REGISTRY}"),
            "campaigns/main_attila/scripting.lua": (
                b'require("mkmp_sp_parity")\nrequire("common/mkmp_debug")\n'
                b'require("common/mkmp_runtime")\nrequire("mechanics/population/mechanics_population")\n'),
            "campaigns/main_attila/common/mkmp_debug.lua": b"return {}\n",
            "campaigns/main_attila/common/mkmp_runtime.lua": b"return {}\n",
            "campaigns/main_attila/mechanics/population/mechanics_population.lua": b"return {}\n",
            "lua_scripts/frontend_scripted.lua": b'require "lua_scripts.fe_script_header"\n',
            "script/_lib/lib_event_handler.lua": b"return {}\r\n",
            "campaigns/main_attila/unreferenced_but_owned.lua": b"return {}\n",
        }
        for name, data in self.sources.items():
            self.write(name, data)
        # Non-Lua assets must not accidentally become an uncompiled mod payload.
        self.write("campaigns/main_attila/movie.ca_vp8", b"not a Lua source")
        self.write("db/example.tsv", b"uncompiled\tdata\n")
        self.write("scripts/pack/Install-MK1212-Pack.ps1", b"# committed installer fixture\n")
        self.write("docs/runtime/PACK_RELEASE.md", b"Committed instructions\n")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "fixture")
        self.sha = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout

    def write(self, name, data):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def test_all_committed_lua_included_dirty_crlf_and_untracked_data_ignored(self):
        first, manifest = pack.make_release(self.repo, self.sha, "baseline")
        self.write("campaigns/main_attila/common/mkmp_debug.lua", b"broken uncommitted code\r\n")
        self.write("lua_scripts/untracked.lua", b"must never ship")
        self.write(pack.REGISTRY, self.sources[pack.REGISTRY].replace(b"false", b"true"))
        second, repeated = pack.make_release(self.repo, self.sha, "baseline")
        self.assertEqual(first, second)
        self.assertEqual(manifest, repeated)
        files, timestamp = independent_pfh4_read(first)
        self.assertEqual(set(files), set(self.sources))
        self.assertEqual(timestamp, 0)
        for path, data in self.sources.items():
            if path != pack.REGISTRY:
                self.assertEqual(files[path], data)
        for row in manifest["files"]:
            expected = pack.git(self.repo, "show", f"{self.sha}:{row['path']}")
            self.assertEqual(row["source_sha256"], pack.digest(expected))
            self.assertEqual(row["git_blob_oid"], self.git("rev-parse", f"{self.sha}:{row['path']}").strip())

    def test_profiles_only_transform_registry_and_leave_source_off(self):
        baseline, base_manifest = pack.make_release(self.repo, self.sha, "baseline")
        experimental, full_manifest = pack.make_release(self.repo, self.sha, "full-experimental")
        base_files, _ = independent_pfh4_read(baseline)
        full_files, _ = independent_pfh4_read(experimental)
        self.assertEqual([p for p in base_files if base_files[p] != full_files[p]], [pack.REGISTRY])
        self.assertIn(b'enabled = false', base_files[pack.REGISTRY])
        self.assertIn(b'all_experimental = false', base_files[pack.REGISTRY])
        self.assertIn(b'enabled = true', full_files[pack.REGISTRY])
        self.assertIn(b'all_experimental = true', full_files[pack.REGISTRY])
        self.assertIn(b'profile = "full-experimental"', full_files[pack.REGISTRY])
        self.assertEqual((self.repo / pack.REGISTRY).read_bytes(), self.sources[pack.REGISTRY])
        self.assertNotEqual(base_manifest["pack"]["sha256"], full_manifest["pack"]["sha256"])
        changes = next(row["transformations"] for row in full_manifest["files"] if row["path"] == pack.REGISTRY)
        self.assertEqual(changes[0]["fields"], {"enabled": True, "all_experimental": True})

    def test_baseline_rejects_committed_enabled_defaults_instead_of_silently_rewriting(self):
        self.write(pack.REGISTRY, self.sources[pack.REGISTRY].replace(b"enabled = false", b"enabled = true", 1))
        self.git("add", pack.REGISTRY)
        self.git("commit", "--quiet", "-m", "unsafe default")
        with self.assertRaisesRegex(pack.PackError, "defaults must all remain false"):
            pack.make_release(self.repo, "HEAD", "baseline")

    def test_publish_preserves_old_outputs_and_uses_committed_support_files(self):
        destination = Path(self.directory.name) / "release"
        self.write("docs/runtime/PACK_RELEASE.md", b"uncommitted instructions")
        manifest = pack.write_release(self.repo, self.sha, "baseline", destination)
        self.assertEqual((destination / "INSTRUKCJA.md").read_bytes(), b"Committed instructions\n")
        stored = json.loads(next(destination.glob("*.manifest.json")).read_text())
        self.assertEqual(stored, manifest)
        old_pack = (destination / manifest["pack"]["filename"]).read_bytes()
        with self.assertRaisesRegex(pack.PackError, "already exists"):
            pack.write_release(self.repo, self.sha, "full-experimental", destination)
        self.assertEqual((destination / manifest["pack"]["filename"]).read_bytes(), old_pack)

    def test_failed_build_publishes_no_partial_directory(self):
        self.git("rm", "campaigns/main_attila/common/mkmp_runtime.lua")
        self.git("commit", "--quiet", "-m", "missing dependency")
        destination = Path(self.directory.name) / "failed-release"
        with self.assertRaisesRegex(pack.PackError, "missing Lua module"):
            pack.write_release(self.repo, "HEAD", "baseline", destination)
        self.assertFalse(destination.exists())

    def test_reference_inventory_counts_nonlua_and_matches_every_lua_path(self):
        reference = Path(self.directory.name) / "original.pack"
        original = dict(self.sources)
        original["ui/base.xml"] = b"base UI asset remains in original pack"
        reference.write_bytes(pack.encode_pfh4(original, timestamp=123))
        inventory = pack.inspect_base_pack(self.repo, self.sha, reference)
        self.assertEqual(inventory["lua_count"], len(self.sources))
        self.assertEqual(inventory["base_pack"]["file_count"], len(self.sources) + 1)
        self.assertEqual(inventory["base_pack"]["sha256"], pack.digest(reference.read_bytes()))
        self.assertEqual(inventory["root_inventory"]["ui"]["files"], 1)
        self.assertTrue(inventory["all_base_lua_paths_covered"])
        self.assertTrue(all(row["relation"] == "identical" for row in inventory["lua_paths"]))
        original["campaigns/main_attila/missing_from_repo.lua"] = b"return 0"
        reference.write_bytes(pack.encode_pfh4(original))
        inventory = pack.inspect_base_pack(self.repo, self.sha, reference)
        self.assertFalse(inventory["all_base_lua_paths_covered"])
        self.assertEqual(inventory["missing_base_lua"], ["campaigns/main_attila/missing_from_repo.lua"])

    def test_manifests_reject_unknown_schema_wrong_profile_and_payload_corruption(self):
        raw, manifest = pack.make_release(self.repo, self.sha, "baseline")
        for mutation in ("schema", "profile", "files", "original-hash", "blob", "transforms"):
            bad = copy.deepcopy(manifest)
            if mutation == "schema":
                bad["schema_version"] = 999
            elif mutation == "profile":
                bad["profile"]["name"] = "full-experimental"
            elif mutation == "files":
                bad["files"].pop()
            elif mutation == "original-hash":
                bad["files"][0]["source_sha256"] = "0" * 64
            elif mutation == "blob":
                bad["files"][0]["git_blob_oid"] = "0" * 40
            else:
                bad["files"][0]["transformations"] = [{"operation": "unreported-change"}]
            with self.subTest(mutation=mutation), self.assertRaises(pack.PackError):
                pack.verify_release(raw, bad)
        with self.assertRaises(pack.PackError):
            pack.verify_release(raw[:-1] + bytes([raw[-1] ^ 1]), manifest)


class PackClosureTests(unittest.TestCase):
    def test_comments_and_strings_do_not_create_fake_require_edges(self):
        code = b'''-- require("missing_one")
--[=[ require("missing_two") ]=]
local help = "require('missing_three')"
local help2 = [==[require("missing_four")]==]
require('common/ok')
'''
        result = pack.check_lua_dependencies({"campaigns/main_attila/a.lua": code,
                                              "campaigns/main_attila/common/ok.lua": b"return {}"})
        self.assertEqual([row["module"] for row in result["resolved"]], ["common/ok"])

    def test_unknown_missing_or_dynamic_imports_fail_without_wildcard_allowance(self):
        for code in (b'require("common/mkmp_debug")', b'require("lua_scripts.typo")',
                     b'require(variable)', b'require("prefix/" .. key)'):
            with self.subTest(code=code), self.assertRaises(pack.PackError):
                pack.check_lua_dependencies({"campaigns/main_attila/scripting.lua": code})
        # An allowed game name at an unreviewed caller is not a blanket exemption.
        with self.assertRaises(pack.PackError):
            pack.check_lua_dependencies({"campaigns/main_attila/other.lua": b'require("att_traits")'})

    def test_missing_runtime_and_population_are_actual_dependency_failures(self):
        for module in ("common/mkmp_debug", "common/mkmp_runtime", "mechanics/population/mechanics_population"):
            source = {"campaigns/main_attila/common/main.lua": f'require("{module}")'.encode()}
            with self.subTest(module=module), self.assertRaisesRegex(pack.PackError, "missing Lua module"):
                pack.check_lua_dependencies(source)
            source["campaigns/main_attila/" + module + ".lua"] = b"return {}"
            self.assertEqual(pack.check_lua_dependencies(source)["status"], "PASS")

    def test_achievement_declaration_is_checked_not_just_present_prefix(self):
        caller = "campaigns/main_attila/ironman/ironman_achievements.lua"
        code = b'''ACHIEVEMENT_KEY_LIST = {"achievement_first", "achievement_missing"}
for _, achievement_key in ipairs(ACHIEVEMENT_KEY_LIST) do
    require("ironman/achievements/" .. achievement_key)
end'''
        files = {caller: code, "campaigns/main_attila/ironman/achievements/achievement_first.lua": b"return {}"}
        with self.assertRaisesRegex(pack.PackError, "missing declared achievement"):
            pack.check_lua_dependencies(files)
        files["campaigns/main_attila/ironman/achievements/achievement_missing.lua"] = b"return {}"
        report = pack.check_lua_dependencies(files)
        self.assertEqual(len(report["dynamic_declarations"][0]["targets"]), 2)

    def test_explicit_battle_entrypoint_must_exist(self):
        files = {"campaigns/main_attila/challenge.lua": b'engine("campaigns/main_attila/battle.lua")'}
        with self.assertRaisesRegex(pack.PackError, "missing literal Lua path"):
            pack.check_lua_dependencies(files)


class PackRepositoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw, cls.manifest = pack.make_release(ROOT, "HEAD", "baseline")
        cls.files, _ = independent_pfh4_read(cls.raw)

    def test_repository_complete_set_includes_previous_missing_modules(self):
        tree = pack.git(ROOT, "ls-tree", "-rz", "HEAD", "--", "campaigns", "lua_scripts", "script")
        expected = {row.split(b"\t", 1)[1].decode() for row in tree.split(b"\0") if row.endswith(b".lua")}
        self.assertEqual(set(self.files), expected)
        for path in ("campaigns/main_attila/common/mkmp_debug.lua",
                     "campaigns/main_attila/common/mkmp_runtime.lua", pack.REGISTRY,
                     "campaigns/main_attila/mechanics/population/mechanics_population.lua"):
            self.assertIn(path, self.files)
        report = self.manifest["lua_dependencies"]
        declared = [row for row in report["dynamic_declarations"] if row["kind"] == "declared-achievement-list"]
        self.assertEqual(len(declared), 1)
        self.assertGreaterEqual(len(declared[0]["targets"]), 26)

    def test_all_packaged_lua_passes_real_lua51_syntax_and_profile_execution(self):
        with tempfile.TemporaryDirectory(prefix="mk1212-pack-lua-") as directory:
            target = Path(directory)
            arguments = []
            for path, data in self.files.items():
                out = target / path
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(data)
                arguments.append(str(out))
            result = run_lua_fixture("scripts/ci/fixtures/pack_syntax.lua", *arguments)
            self.assertIn(f"PASS syntax: {len(self.files)}", result.stdout)
            original_registry = pack.git(ROOT, "show", f"HEAD:{pack.REGISTRY}")
            for profile in pack.PROFILES:
                data, _ = pack.apply_profile(original_registry, profile, self.manifest["source_commit_sha"])
                (target / pack.REGISTRY).write_bytes(data)
                result = run_lua_fixture("scripts/ci/fixtures/pack_profile.lua",
                                         str(target / pack.REGISTRY), profile, self.manifest["source_commit_sha"])
                self.assertIn("PASS profile: " + profile, result.stdout)


if __name__ == "__main__":
    unittest.main()
