#!/usr/bin/env python3
"""Reproducible, complete MK1212 Lua overlay for Attila; no game install needed.

The deliberately small PFH4 subset follows RPFM at
64e4b8e25c7e6729f6742f88ed27d8d8649a0478 (MIT), independently implemented here.
See docs/runtime/PACK_RELEASE.md for format authority and deployment boundaries.
Only committed Git blobs are inputs. Working-tree Lua is never packaged.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import NamedTuple


ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOTS = ("campaigns", "lua_scripts", "script")
REGISTRY = "campaigns/main_attila/mkmp_sp_parity.lua"
PROFILES = ("baseline", "full-experimental")
MAX_FILES = 4096
MAX_BYTES = 64 * 1024 * 1024
SCHEMA = "mk1212-script-pack-v1"
RPFM_COMMIT = "64e4b8e25c7e6729f6742f88ed27d8d8649a0478"

# Exact module AND caller pairs: never a prefix/wildcard escape for a missing mod
# file. These are existing Attila-library calls observed in this repository;
# they are supplied by the user's game, not redistributed by this overlay.
GAME_MODULES = {
    "att_traits": {"campaigns/main_attila/scripting.lua"},
    "lua_scripts.Campaign_Script_Header": {"campaigns/main_attila/scripting.lua"},
    "data.lua_scripts.all_scripted": {"lua_scripts/frontend_scripted.lua"},
    "lua_scripts.fe_script_header": {"lua_scripts/frontend_scripted.lua"},
    "lua_scripts.EpisodicScripting": {"lua_scripts/util.lua"},
    "lib_common": {"lua_scripts/logging_callbacks.lua"},
    "lua_scripts.episodicscripting": {
        "lua_scripts/logging_callbacks.lua",
        "campaigns/main_attila/startingbattles/battles/battle_lasnavas/battle_lasnavas.lua",
    },
    "lua_scripts.Battle_Script_Header": {
        "campaigns/main_attila/challenges/battles/battle_no_retreat.lua",
    },
    "lua_scripts/battle_script_header": {
        "campaigns/main_attila/startingbattles/battles/battle_lasnavas/battle_lasnavas.lua",
    },
    "battle_generic_advice": {
        "campaigns/main_attila/startingbattles/battles/battle_lasnavas/battle_lasnavas.lua",
    },
    "battle_generic_strings": {
        "campaigns/main_attila/startingbattles/battles/battle_lasnavas/battle_lasnavas.lua",
    },
}


class PackError(ValueError):
    """Invalid source, incomplete dependencies, or inconsistent release output."""


class Token(NamedTuple):
    kind: str
    value: str
    start: int
    end: int


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def lua_tokens(text: str) -> list[Token]:
    """Lex the tokens needed for load declarations; do not execute campaign Lua.

    Comments, quoted strings and Lua long brackets are recognized before names.
    This is dependency analysis, not a replacement for a Lua 5.1 syntax check.
    """
    result = []
    i = 0
    while i < len(text):
        if text[i].isspace() or text[i] == "\ufeff":
            i += 1
            continue
        start = i
        comment = text.startswith("--", i)
        if comment:
            i += 2
        long = re.match(r"\[(=*)\[", text[i:]) if text[i:i + 1] == "[" else None
        if long:
            content_start = i + len(long.group())
            close = "]" + long.group(1) + "]"
            end = text.find(close, content_start)
            if end < 0:
                raise PackError("unterminated Lua long string/comment")
            i = end + len(close)
            if not comment:
                result.append(Token("string", text[content_start:end], start, i))
            continue
        if comment:
            end = text.find("\n", i)
            i = len(text) if end < 0 else end + 1
            continue
        if text[i] in "\"'":
            quote = text[i]
            value = []
            i += 1
            while i < len(text) and text[i] != quote:
                if text[i] == "\\":
                    i += 1
                    if i >= len(text):
                        raise PackError("unterminated Lua escape")
                    number = re.match(r"[0-9]{1,3}", text[i:])
                    if number:
                        code = int(number.group())
                        if code > 255:
                            raise PackError("invalid Lua decimal escape")
                        value.append(chr(code))
                        i += len(number.group())
                        continue
                    escaped = {"a": "\a", "b": "\b", "f": "\f", "n": "\n",
                               "r": "\r", "t": "\t", "v": "\v"}
                    value.append(escaped.get(text[i], text[i]))
                else:
                    value.append(text[i])
                i += 1
            if i >= len(text):
                raise PackError("unterminated Lua quoted string")
            i += 1
            result.append(Token("string", "".join(value), start, i))
        elif text[i].isalpha() or text[i] == "_":
            i += 1
            while i < len(text) and (text[i].isalnum() or text[i] == "_"):
                i += 1
            result.append(Token("name", text[start:i], start, i))
        else:
            i += 2 if text.startswith("..", i) else 1
            result.append(Token("symbol", text[start:i], start, i))
    return result


def assigned_table(tokens: list[Token], name: str) -> list[Token]:
    starts = [i + 3 for i in range(len(tokens) - 2)
              if [t.value for t in tokens[i:i + 3]] == [name, "=", "{"]]
    if len(starts) != 1:
        raise PackError(f"expected exactly one literal {name} table")
    start = starts[0]
    depth = 1
    for i in range(start, len(tokens)):
        if tokens[i].value == "{" and tokens[i].kind == "symbol":
            depth += 1
        elif tokens[i].value == "}" and tokens[i].kind == "symbol":
            depth -= 1
            if depth == 0:
                return tokens[start:i]
    raise PackError(f"unterminated {name} table")


def boolean_table(tokens: list[Token], name: str) -> dict[str, Token]:
    table = assigned_table(tokens, name)
    fields = {}
    i = 0
    while i < len(table):
        if i + 2 >= len(table):
            raise PackError(f"malformed boolean table {name}")
        key, equals, value = table[i:i + 3]
        if (key.kind != "name" or equals.value != "=" or
                value.kind != "name" or value.value not in {"true", "false"} or
                key.value in fields):
            raise PackError(f"nonliteral/duplicate boolean in {name}")
        fields[key.value] = value
        i += 3
        if i < len(table):
            if table[i].value not in {",", ";"}:
                raise PackError(f"malformed separator in {name}")
            i += 1
    return fields


def apply_profile(data: bytes, profile: str, source_sha: str) -> tuple[bytes, list[dict]]:
    if profile not in PROFILES or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise PackError("unknown profile or invalid full source commit SHA")
    text = data.decode("utf-8")
    tokens = lua_tokens(text)
    if any(t.kind == "name" and t.value == "MKMP_PACK_ID" for t in tokens):
        raise PackError("source registry already contains generated MKMP_PACK_ID")
    fields = boolean_table(tokens, "MKMP_SP_PARITY")
    if not {"enabled", "all_experimental"}.issubset(fields):
        raise PackError("parity registry is missing its two master switches")
    if any(t.value != "false" for t in fields.values()):
        raise PackError("committed parity defaults must all remain false")
    blocked = boolean_table(tokens, "blocked_features")
    for feature in ("ironman", "change_capital", "legacy_networking"):
        if feature not in blocked or blocked[feature].value != "true":
            raise PackError(f"missing blocked MP feature: {feature}")
    changes = []
    if profile == "full-experimental":
        for key in sorted(("enabled", "all_experimental"),
                          key=lambda k: fields[k].start, reverse=True):
            token = fields[key]
            text = text[:token.start] + "true" + text[token.end:]
        changes.append({"operation": "set-parity-master-switches-v1",
                        "fields": {"enabled": True, "all_experimental": True}})
    identity = pack_identity(source_sha, profile)
    # Keep a possible UTF-8 BOM at the beginning, never in the middle of Lua.
    bom = "\ufeff" if text.startswith("\ufeff") else ""
    text = bom + identity + text.removeprefix("\ufeff")
    changes.append({"operation": "prepend-pack-identity-v1",
                    "source": source_sha, "profile": profile})
    return text.encode("utf-8"), changes


def pack_identity(source_sha: str, profile: str) -> str:
    return ("-- Generated pack identity; diagnostic metadata only.\n"
            f'MKMP_PACK_ID = {{ source = "{source_sha}", profile = "{profile}" }}\n')


def registry_source(data: bytes, profile: str, sha: str) -> bytes:
    """Invert only our canonical, recorded build transforms for hash checking."""
    text = data.decode("utf-8")
    bom = "\ufeff" if text.startswith("\ufeff") else ""
    text = text.removeprefix("\ufeff")
    identity = pack_identity(sha, profile)
    if not text.startswith(identity):
        raise PackError("packaged identity is not the canonical build prefix")
    text = bom + text[len(identity):]
    if profile == "full-experimental":
        fields = boolean_table(lua_tokens(text), "MKMP_SP_PARITY")
        for key in sorted(("enabled", "all_experimental"),
                          key=lambda k: fields[k].start, reverse=True):
            token = fields[key]
            text = text[:token.start] + "false" + text[token.end:]
    return text.encode("utf-8")


def validate_path(path: str) -> None:
    if (not path or "\\" in path or not re.fullmatch(r"[A-Za-z0-9_./-]+", path)
            or any(part in {"", ".", ".."} for part in path.split("/"))
            or PurePosixPath(path).is_absolute()):
        raise PackError(f"unsafe or unsupported archive path: {path!r}")


def require_arguments(tokens: list[Token], i: int) -> list[Token]:
    if i + 1 >= len(tokens):
        raise PackError("require without argument")
    if tokens[i + 1].kind == "string":
        return [tokens[i + 1]]
    if tokens[i + 1].value != "(":
        raise PackError("unreviewed require expression or alias")
    start = i + 2
    depth = 1
    for j in range(start, len(tokens)):
        if tokens[j].kind == "symbol":
            if tokens[j].value == "(":
                depth += 1
            elif tokens[j].value == ")":
                depth -= 1
                if depth == 0:
                    return tokens[start:j]
    raise PackError("unterminated require call")


def check_lua_dependencies(files: dict[str, bytes]) -> dict:
    paths = {p.casefold(): p for p in files}
    if len(paths) != len(files):
        raise PackError("case-insensitive archive path collision")
    resolved, external, dynamic, literal_scripts = [], [], [], []
    for source, data in sorted(files.items()):
        try:
            tokens = lua_tokens(data.decode("utf-8-sig"))
        except (UnicodeError, PackError) as exc:
            raise PackError(f"{source}: {exc}") from exc
        for i, token in enumerate(tokens):
            if token.kind == "string" and token.value.endswith(".lua"):
                # Engine battle entry points can be literal paths, not require().
                candidate = token.value.removeprefix("data/")
                if candidate.startswith(tuple(root + "/" for root in SOURCE_ROOTS)):
                    if candidate.casefold() not in paths:
                        raise PackError(f"{source}: missing literal Lua path {candidate}")
                    literal_scripts.append({"source": source, "target": paths[candidate.casefold()]})
            if token.kind != "name" or token.value != "require":
                continue
            if i and tokens[i - 1].value in {".", ":"}:
                raise PackError(f"{source}: unreviewed alternate require loader")
            args = require_arguments(tokens, i)
            values = [t.value for t in args]
            if len(args) == 1 and args[0].kind == "string":
                module = args[0].value
                normalized = module.replace(".", "/").removeprefix("data/")
                candidates = [normalized + ".lua",
                              "campaigns/main_attila/" + normalized + ".lua",
                              "campaigns/main_attila/factions/" + normalized + ".lua"]
                target = next((paths[p.casefold()] for p in candidates if p.casefold() in paths), None)
                if target:
                    resolved.append({"source": source, "module": module, "target": target})
                elif source in GAME_MODULES.get(module, set()):
                    external.append({"source": source, "module": module, "provider": "installed-attila-game"})
                else:
                    raise PackError(f"{source}: missing Lua module {module!r}")
            elif (source == "campaigns/main_attila/ironman/ironman_achievements.lua"
                  and values == ["ironman/achievements/", "..", "achievement_key"]
                  and args[0].kind == "string"):
                declarations = assigned_table(tokens, "ACHIEVEMENT_KEY_LIST")
                keys = []
                for j, declaration in enumerate(declarations):
                    if j % 2 == 0 and declaration.kind == "string":
                        keys.append(declaration.value)
                    elif j % 2 == 1 and declaration.value == ",":
                        continue
                    else:
                        raise PackError("achievement keys must be a literal ordered string list")
                if not keys or len(set(keys)) != len(keys):
                    raise PackError("empty/duplicate achievement declaration")
                targets = ["campaigns/main_attila/ironman/achievements/" + key + ".lua" for key in keys]
                for target in targets:
                    if target not in files:
                        raise PackError(f"{source}: missing declared achievement {target}")
                dynamic.append({"source": source, "kind": "declared-achievement-list", "targets": targets})
            elif source == "campaigns/main_attila/scripting.lua" and values == ["scriptname"]:
                # The repository's existing optional faction loader uses pcall;
                # absent faction/_intro modules are intentionally tolerated.
                preceding = [t.value for t in tokens[max(0, i - 5):i]]
                if preceding != ["pcall", "(", "function", "(", ")"]:
                    raise PackError("optional faction require must remain protected by pcall")
                targets = sorted(p for p in files if p.startswith("campaigns/main_attila/factions/"))
                dynamic.append({"source": source, "kind": "optional-protected-faction-loader",
                                "targets": targets,
                                "missing_policy": "existing pcall handles absent faction and faction_intro scripts"})
            else:
                raise PackError(f"{source}: unreviewed dynamic require {values!r}")
    return {"resolved": resolved, "external_game_modules": external,
            "dynamic_declarations": dynamic, "literal_script_paths": literal_scripts,
            "status": "PASS", "scope": "repository Lua dependency closure; not Attila runtime proof"}


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(repo), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise PackError(result.stderr.decode("utf-8", errors="replace").strip())
    return result.stdout


def committed_sources(repo: Path, ref: str) -> tuple[str, str, dict[str, bytes], dict[str, str]]:
    if not ref or ref.startswith("-"):
        raise PackError("source ref must name a committed revision")
    sha = git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise PackError("expected a full Git SHA-1 commit ID")
    tree = git(repo, "rev-parse", sha + "^{tree}").decode().strip()
    entries = []
    for item in git(repo, "ls-tree", "-rz", sha, "--", *SOURCE_ROOTS).split(b"\0"):
        if not item:
            continue
        metadata, path_bytes = item.split(b"\t", 1)
        path = path_bytes.decode("utf-8")
        if not path.lower().endswith(".lua"):
            continue
        mode, kind, oid = metadata.decode("ascii").split()
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise PackError(f"Lua source must be a regular committed file: {path}")
        validate_path(path)
        entries.append((path, oid))
    if not entries or len(entries) > MAX_FILES:
        raise PackError("missing or excessive committed Lua sources")
    result = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"],
                            input="".join(oid + "\n" for _, oid in entries).encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode or len(result.stdout) > MAX_BYTES:
        raise PackError("Git blob read failed or exceeded archive source budget")
    cursor = 0
    sources, blobs = {}, {}
    for path, expected in entries:
        end = result.stdout.find(b"\n", cursor)
        header = result.stdout[cursor:end].decode("ascii").split()
        if len(header) != 3 or header[:2] != [expected, "blob"]:
            raise PackError(f"invalid Git batch result for {path}")
        size = int(header[2])
        cursor = end + 1
        data = result.stdout[cursor:cursor + size]
        if len(data) != size or result.stdout[cursor + size:cursor + size + 1] != b"\n":
            raise PackError(f"incomplete Git blob for {path}")
        cursor += size + 1
        sources[path], blobs[path] = data, expected
    if cursor != len(result.stdout):
        raise PackError("unexpected trailing Git batch data")
    required = {REGISTRY, "campaigns/main_attila/scripting.lua",
                "lua_scripts/frontend_scripted.lua", "script/_lib/lib_event_handler.lua"}
    if required - sources.keys():
        raise PackError(f"missing MK1212 entrypoints: {sorted(required - sources.keys())}")
    return sha, tree, sources, blobs


def encode_pfh4(files: dict[str, bytes], *, timestamp: int = 0) -> bytes:
    if not files or len(files) > MAX_FILES or not 0 <= timestamp <= 0xFFFFFFFF:
        raise PackError("invalid PFH4 file count/timestamp")
    if len({path.casefold() for path in files}) != len(files):
        raise PackError("case-insensitive archive path collision")
    index, payload = bytearray(), bytearray()
    for path in sorted(files, key=lambda p: p.replace("/", "\\").lower()):
        validate_path(path)
        content = files[path]
        if len(content) > MAX_BYTES:
            raise PackError(f"file exceeds archive budget: {path}")
        index.extend(struct.pack("<I", len(content)))
        index.extend(path.replace("/", "\\").encode("ascii") + b"\0")
        payload.extend(content)
    # PFH4 Mod=3, no flags, no dependencies, no per-file timestamps/compression.
    result = struct.pack("<4s6I", b"PFH4", 3, 0, 0, len(files), len(index), timestamp)
    result += index + payload
    if len(result) > MAX_BYTES:
        raise PackError("archive exceeds size budget")
    return result


def read_pfh4(data: bytes) -> tuple[dict[str, bytes], int]:
    if len(data) < 28 or len(data) > MAX_BYTES:
        raise PackError("invalid archive size")
    signature, flags, deps, deps_size, count, index_size, timestamp = struct.unpack_from("<4s6I", data)
    if signature != b"PFH4" or flags != 3 or deps != 0 or deps_size != 0:
        raise PackError("expected PFH4 Mod with no flags/dependencies")
    if not 0 < count <= MAX_FILES or 28 + index_size > len(data):
        raise PackError("invalid archive index bounds")
    cursor, payload = 28, 28 + index_size
    files, seen = {}, set()
    for _ in range(count):
        if cursor + 5 > 28 + index_size:
            raise PackError("truncated archive index")
        size = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        end = data.find(b"\0", cursor, 28 + index_size)
        if end < 0:
            raise PackError("unterminated archive path")
        try:
            raw_path = data[cursor:end].decode("ascii")
        except UnicodeError as exc:
            raise PackError("non-ASCII archive path") from exc
        if "/" in raw_path:
            raise PackError("PFH4 stored paths must use backslashes")
        path = raw_path.replace("\\", "/")
        validate_path(path)
        if path.casefold() in seen or payload + size > len(data):
            raise PackError("duplicate path or truncated archive payload")
        seen.add(path.casefold())
        files[path] = data[payload:payload + size]
        payload += size
        cursor = end + 1
    if cursor != 28 + index_size or payload != len(data):
        raise PackError("archive contains trailing or inconsistent bytes")
    return files, timestamp


def inspect_base_pack(repo: Path, ref: str, path: Path) -> dict:
    """Inventory a large original pack without extracting/redistributing assets.

    This reader supports only the observed plain PFH4 Mod format. Other flags
    require an explicit review, not guessed offsets or skipped headers.
    """
    sha, _, sources, _ = committed_sources(repo, ref)
    source_paths = {name.casefold(): name for name in sources}
    pack_hash = hashlib.sha256()
    roots, lua = {}, []
    with path.open("rb") as stream:
        header = stream.read(28)
        if len(header) != 28:
            raise PackError("reference pack header is incomplete")
        magic, flags, deps, deps_size, count, index_size, timestamp = struct.unpack("<4s6I", header)
        if magic != b"PFH4" or flags != 3 or deps != 0 or deps_size != 0:
            raise PackError("reference inventory requires plain PFH4 Mod with no dependencies")
        if not 0 < count <= 100000 or not 0 < index_size <= 16 * 1024 * 1024:
            raise PackError("reference pack index exceeds inventory limits")
        index = stream.read(index_size)
        if len(index) != index_size:
            raise PackError("reference pack index is incomplete")
        pack_hash.update(header)
        pack_hash.update(index)
        rows, seen, offset = [], set(), 0
        for _ in range(count):
            if offset + 5 > len(index):
                raise PackError("reference pack index count is inconsistent")
            size = struct.unpack_from("<I", index, offset)[0]
            end = index.find(b"\0", offset + 4)
            if end < 0:
                raise PackError("reference pack path is unterminated")
            name = index[offset + 4:end].decode("utf-8").replace("\\", "/")
            if name.casefold() in seen:
                raise PackError("reference pack contains colliding paths")
            seen.add(name.casefold())
            rows.append((name, size))
            offset = end + 1
        if offset != index_size:
            raise PackError("reference pack index has trailing bytes")
        for name, size in rows:
            root = name.split("/", 1)[0]
            summary = roots.setdefault(root, {"files": 0, "bytes": 0})
            summary["files"] += 1
            summary["bytes"] += size
            is_lua = name.lower().endswith(".lua")
            content_hash = hashlib.sha256() if is_lua else None
            remaining = size
            while remaining:
                chunk = stream.read(min(remaining, 1024 * 1024))
                if not chunk:
                    raise PackError("reference pack payload is incomplete")
                remaining -= len(chunk)
                pack_hash.update(chunk)
                if content_hash is not None:
                    content_hash.update(chunk)
            if is_lua:
                source_path = source_paths.get(name.casefold())
                base_hash = content_hash.hexdigest()
                source_hash = digest(sources[source_path]) if source_path else None
                lua.append({"base_path": name, "base_size": size, "base_sha256": base_hash,
                            "repository_path": source_path, "repository_sha256": source_hash,
                            "relation": ("identical" if source_hash == base_hash else
                                         "overridden" if source_path else "missing")})
        if stream.read(1):
            raise PackError("reference pack contains trailing bytes")
        size = stream.tell()
    missing = [row["base_path"] for row in lua if row["repository_path"] is None]
    base_lua = {row["base_path"].casefold() for row in lua}
    return {"schema": "mk1212-base-script-inventory-v1", "schema_version": 1,
            "source_commit_sha": sha,
            "base_pack": {"filename": path.name, "size": size, "sha256": pack_hash.hexdigest(),
                          "format": "PFH4", "type": "Mod", "type_value": 3, "flags": 0,
                          "dependencies_count": 0, "file_count": count,
                          "file_index_size": index_size, "timestamp": timestamp},
            "root_inventory": dict(sorted(roots.items())),
            "lua_count": len(lua), "lua_bytes": sum(row["base_size"] for row in lua),
            "repository_lua_count": len(sources), "missing_base_lua": missing,
            "additional_repository_lua": sorted(p for p in sources if p.casefold() not in base_lua),
            "all_base_lua_paths_covered": not missing, "lua_paths": lua,
            "scope": "file/path/content inventory; actual Attila load order and MP are not proven"}


def make_release(repo: Path, ref: str, profile: str) -> tuple[bytes, dict]:
    sha, tree, original, blobs = committed_sources(repo, ref)
    files = dict(original)
    files[REGISTRY], transformations = apply_profile(original[REGISTRY], profile, sha)
    dependencies = check_lua_dependencies(files)
    packed = encode_pfh4(files)
    decoded, timestamp = read_pfh4(packed)
    if decoded != files or timestamp != 0:
        raise PackError("pack readback differs from build inputs")
    name = f"mk1212_scripts_{profile.replace('-', '_')}_{sha[:12]}.pack"
    rows = []
    for path in sorted(files):
        rows.append({"path": path, "pack_path": path.replace("/", "\\"),
                     "git_blob_oid": blobs[path], "source_sha256": digest(original[path]),
                     "source_size": len(original[path]), "sha256": digest(files[path]),
                     "size": len(files[path]),
                     "transformations": transformations if path == REGISTRY else []})
    manifest = {
        "schema": SCHEMA, "schema_version": 1,
        "source_repository": "https://github.com/karnalooch/MK1212Scripts",
        "source_commit_sha": sha, "source_tree_sha": tree,
        "builder": {"path": "scripts/pack/build_mk1212_pack.py",
                    "sha256": digest(Path(__file__).read_bytes()),
                    "format_reference_repository": "https://github.com/Frodo45127/rpfm",
                    "format_reference_commit": RPFM_COMMIT},
        "profile": {"name": profile, "registry": REGISTRY,
                    "enabled": profile == "full-experimental",
                    "all_experimental": profile == "full-experimental",
                    "committed_defaults_verified_off": True,
                    "runtime_status": "NOT RUN: exact-build two-PC Attila validation still required"},
        "pack": {"filename": name, "size": len(packed), "sha256": digest(packed),
                 "format": "PFH4", "type": "Mod", "type_value": 3, "flags": 0,
                 "timestamp": 0, "file_count": len(files)},
        "contents": {"selection": "all committed .lua files in campaigns/, lua_scripts/, script/",
                     "requires_installed_base_mod": True,
                     "embedded_upstream_mod_helpers": [p for p in (
                         "lua_scripts/change_capital_binaries.lua", "lua_scripts/slots_binaries.lua") if p in files],
                     "not_included": ["game binaries", "native DLL", "movies", "UI assets",
                                      "database/TSV data", "base-game Lua libraries"]},
        "lua_dependencies": dependencies, "files": rows,
    }
    verify_release(packed, manifest)
    return packed, manifest


def verify_release(packed: bytes, manifest: dict) -> None:
    if manifest.get("schema") != SCHEMA or manifest.get("schema_version") != 1:
        raise PackError("unknown manifest schema")
    sha = manifest.get("source_commit_sha", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise PackError("invalid source commit in manifest")
    profile = manifest.get("profile", {})
    if profile.get("name") not in PROFILES:
        raise PackError("unknown manifest profile")
    expected = profile["name"] == "full-experimental"
    if (profile.get("enabled") is not expected or profile.get("all_experimental") is not expected
            or profile.get("committed_defaults_verified_off") is not True):
        raise PackError("inconsistent manifest profile fields")
    files, timestamp = read_pfh4(packed)
    metadata = manifest.get("pack", {})
    expected_name = f"mk1212_scripts_{profile['name'].replace('-', '_')}_{sha[:12]}.pack"
    if (timestamp != 0 or metadata.get("sha256") != digest(packed)
            or metadata.get("size") != len(packed) or metadata.get("file_count") != len(files)
            or metadata.get("format") != "PFH4" or metadata.get("type_value") != 3
            or metadata.get("flags") != 0 or metadata.get("timestamp") != 0
            or metadata.get("filename") != expected_name):
        raise PackError("pack identity/header disagrees with manifest")
    rows = manifest.get("files", [])
    if len(rows) != len(files) or len({row.get("path") for row in rows}) != len(rows):
        raise PackError("manifest file list is incomplete or duplicated")
    for row in rows:
        path = row.get("path")
        if path not in files or not path.endswith(".lua"):
            raise PackError(f"unexpected manifest file: {path}")
        if (row.get("sha256") != digest(files[path]) or row.get("size") != len(files[path])
                or row.get("pack_path") != path.replace("/", "\\")):
            raise PackError(f"manifest payload mismatch: {path}")
        original = registry_source(files[path], profile["name"], sha) if path == REGISTRY else files[path]
        blob = hashlib.sha1(b"blob " + str(len(original)).encode("ascii") + b"\0" + original).hexdigest()
        if (row.get("source_sha256") != digest(original) or row.get("source_size") != len(original)
                or row.get("git_blob_oid") != blob):
            raise PackError(f"manifest original source/blob mismatch: {path}")
        if path == REGISTRY:
            rebuilt, transformations = apply_profile(original, profile["name"], sha)
            if rebuilt != files[path] or row.get("transformations") != transformations:
                raise PackError("registry transforms do not reproduce recorded source/output")
        elif row.get("transformations") != []:
            raise PackError(f"unexpected source transformation: {path}")
    if REGISTRY not in files:
        raise PackError("missing packaged parity registry")
    tokens = lua_tokens(files[REGISTRY].decode("utf-8-sig"))
    fields = boolean_table(tokens, "MKMP_SP_PARITY")
    for key, token in fields.items():
        desired = expected if key in {"enabled", "all_experimental"} else False
        if (token.value == "true") != desired:
            raise PackError(f"packaged profile disagrees with manifest: {key}")
    if not {"enabled", "all_experimental"}.issubset(fields):
        raise PackError("missing packaged master switches")
    blocked = boolean_table(tokens, "blocked_features")
    for feature in ("ironman", "change_capital", "legacy_networking"):
        if feature not in blocked or blocked[feature].value != "true":
            raise PackError(f"missing packaged blocked feature: {feature}")
    identity = assigned_table(tokens, "MKMP_PACK_ID")
    if [t.value for t in identity] != ["source", "=", sha, ",", "profile", "=", profile["name"]]:
        raise PackError("packaged diagnostic identity disagrees with manifest")
    if check_lua_dependencies(files) != manifest.get("lua_dependencies"):
        raise PackError("packaged Lua dependency report disagrees with manifest")


def write_release(repo: Path, ref: str, profile: str, destination: Path) -> dict:
    # Publish an immutable directory only after every output is complete/verified.
    # Refusing existing destinations preserves old releases, including on failure.
    if destination.exists() or destination.is_symlink():
        raise PackError(f"output directory already exists: {destination}")
    packed, manifest = make_release(repo, ref, profile)
    # Every delivered support file is also read from the selected commit. This
    # deliberately fails for revisions predating the release tooling/runbook.
    support = {}
    delivery = []
    for source_path, output_name in (
        ("scripts/pack/Install-MK1212-Pack.ps1", "Install-MK1212-Pack.ps1"),
        ("docs/runtime/PACK_RELEASE.md", "INSTRUKCJA.md"),
    ):
        original = git(repo, "show", f"{manifest['source_commit_sha']}:{source_path}")
        data = original
        transforms = []
        if output_name == "INSTRUKCJA.md":
            # A flat download has no ../research or evidence subdirectory.
            # Point its two repo-relative links at the same immutable commit.
            base_url = f"https://github.com/karnalooch/MK1212Scripts/blob/{manifest['source_commit_sha']}/docs/"
            text = data.decode("utf-8")
            text = re.sub(r"\]\(\.\./research/([^()]+)\)",
                          lambda match: "](" + base_url + "research/" + match.group(1) + ")", text)
            text = re.sub(r"\]\(evidence/([^()]+)\)",
                          lambda match: "](" + base_url + "runtime/evidence/" + match.group(1) + ")", text)
            data = text.encode("utf-8")
            if data != original:
                transforms.append("resolve-exported-document-links-to-source-commit-v1")
        support[output_name] = data
        delivery.append({"filename": output_name, "source_path": source_path,
                         "source_commit_sha": manifest["source_commit_sha"], "sha256": digest(data),
                         "source_sha256": digest(original), "transformations": transforms})
    manifest["delivery_files"] = delivery
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".mk1212-pack-", dir=destination.parent))
    try:
        pack_name = manifest["pack"]["filename"]
        (temporary / pack_name).write_bytes(packed)
        manifest_name = pack_name.removesuffix(".pack") + ".manifest.json"
        (temporary / manifest_name).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        for name, data in support.items():
            (temporary / name).write_bytes(data)
        checksums = "".join(f"{digest(path.read_bytes())}  {path.name}\n"
                            for path in sorted(temporary.iterdir()))
        (temporary / "SHA256SUMS.txt").write_text(checksums, encoding="ascii")
        verify_release((temporary / pack_name).read_bytes(),
                       json.loads((temporary / manifest_name).read_text(encoding="utf-8")))
        if destination.exists() or destination.is_symlink():
            raise PackError("output directory appeared during build; refusing replacement")
        os.rename(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="build all committed gameplay Lua; never the working tree")
    build.add_argument("--repo", type=Path, default=ROOT)
    build.add_argument("--ref", required=True)
    build.add_argument("--profile", choices=PROFILES, default="baseline")
    build.add_argument("--output-dir", type=Path, required=True)
    verify = commands.add_parser("verify", help="check pack/profile/dependency closure against manifest")
    verify.add_argument("--pack", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    inspect = commands.add_parser("inspect-base", help="inventory original pack and compare every Lua path")
    inspect.add_argument("--repo", type=Path, default=ROOT)
    inspect.add_argument("--ref", required=True)
    inspect.add_argument("--pack", type=Path, required=True)
    inspect.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "build":
            manifest = write_release(args.repo, args.ref, args.profile, args.output_dir)
        elif args.command == "inspect-base":
            if args.output.exists() or args.output.is_symlink():
                raise PackError("reference evidence already exists; refusing overwrite")
            inventory = inspect_base_pack(args.repo, args.ref, args.pack)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open("x", encoding="utf-8") as stream:
                stream.write(json.dumps(inventory, indent=2, sort_keys=True) + "\n")
            print(json.dumps({key: value for key, value in inventory.items()
                              if key not in {"lua_paths", "root_inventory"}}, indent=2))
            return 0 if inventory["all_base_lua_paths_covered"] else 1
        else:
            manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
            if args.pack.name != manifest.get("pack", {}).get("filename"):
                raise PackError("pack filename disagrees with manifest")
            verify_release(args.pack.read_bytes(), manifest)
        print(json.dumps({"status": "PASS", "source_commit_sha": manifest["source_commit_sha"],
                          "profile": manifest["profile"]["name"], "pack": manifest["pack"]}, indent=2))
        return 0
    except (PackError, OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
