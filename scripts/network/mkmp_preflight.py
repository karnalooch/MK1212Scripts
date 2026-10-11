"""Read-only exact-file environment identity for the MK1212 coordinator.

Load order is supplied from the actual launch configuration; this tool does not
invent enabled mods from a directory listing or infer Steam ownership from a file.
"""
from __future__ import annotations

import ctypes
import hashlib
import os
from pathlib import Path
import platform
import re
from typing import Any

from mkmp_transport import ProtocolError, SHA256, atomic_json, digest, exact_fields, load_json


PREFLIGHT_SCHEMA = 1
MAX_MODS = 256
MAX_ORDER_BYTES = 256 * 1024
MAX_TEXT_BYTES = 2 * 1024 * 1024


def file_identity(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise ProtocolError(f"required_file_missing:{path.name}")
    before = path.stat()
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    after = path.stat()
    if before.st_size != after.st_size or before.st_mtime_ns != after.st_mtime_ns:
        raise ProtocolError(f"file_changed_during_preflight:{path.name}")
    # Byte counts are strings: large game files need not fit Attila's Lua float.
    return {"sha256": hasher.hexdigest(), "bytes": str(after.st_size)}


def windows_file_version(path: Path) -> str:
    if os.name != "nt":
        return "unavailable_non_windows"
    try:
        version = ctypes.WinDLL("version", use_last_error=True)
        version.GetFileVersionInfoSizeW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)]
        version.GetFileVersionInfoSizeW.restype = ctypes.c_uint32
        unused = ctypes.c_uint32(0)
        size = version.GetFileVersionInfoSizeW(str(path), ctypes.byref(unused))
        if not size or size > MAX_TEXT_BYTES:
            return "unavailable"
        block = ctypes.create_string_buffer(size)
        version.GetFileVersionInfoW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        version.GetFileVersionInfoW.restype = ctypes.c_int
        if not version.GetFileVersionInfoW(str(path), 0, size, block):
            return "unavailable"
        pointer = ctypes.c_void_p()
        length = ctypes.c_uint32()
        version.VerQueryValueW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint32)]
        version.VerQueryValueW.restype = ctypes.c_int
        if not version.VerQueryValueW(block, "\\", ctypes.byref(pointer), ctypes.byref(length)) or length.value < 52:
            return "unavailable"
        words = ctypes.cast(pointer, ctypes.POINTER(ctypes.c_uint32 * 13)).contents
        if words[0] != 0xFEEF04BD:
            return "unavailable"
        return ".".join(str(number) for number in (
            words[2] >> 16, words[2] & 0xFFFF, words[3] >> 16, words[3] & 0xFFFF))
    except (AttributeError, OSError, ValueError):
        return "unavailable"


def _read_text(path: Path, budget: int) -> str:
    if path.stat().st_size > budget:
        raise ProtocolError(f"text_file_budget:{path.name}")
    data = path.read_bytes()
    try:
        if data.startswith((b"\xff\xfe", b"\xfe\xff")):
            return data.decode("utf-16")
        return data.decode("utf-8-sig")
    except UnicodeError as error:
        raise ProtocolError(f"text_encoding_not_supported:{path.name}") from error


def read_load_order(path: Path, data_directory: Path) -> list[dict[str, Any]]:
    lines = _read_text(path, MAX_ORDER_BYTES).splitlines()
    result: list[dict[str, Any]] = []
    names: set[str] = set()
    for line in lines:
        line = line.strip()
        if not line or line.startswith(("#", "//")):
            continue
        match = re.fullmatch(r'mod\s+"([^"\r\n]+\.pack)"\s*;', line, re.IGNORECASE)
        if match:
            name = match.group(1)
        elif line.lower().endswith(".pack") and not line.startswith("mod "):
            name = line
        else:
            raise ProtocolError("load_order_requires_mod_lines_or_one_pack_path_per_line")
        pack = Path(name)
        if not pack.is_absolute():
            pack = data_directory / pack
        key = pack.name.lower()
        if key in names:
            raise ProtocolError(f"duplicate_load_order_name:{pack.name}")
        names.add(key)
        result.append({"name": key, **file_identity(pack)})
        if len(result) > MAX_MODS:
            raise ProtocolError("mod_count_budget")
    if not result:
        raise ProtocolError("empty_load_order")
    return result


def build_preflight(*, game_directory: Path, manifest_path: Path, pack_path: Path,
                    load_order_path: Path, game_build: str, steam_branch: str,
                    save_path: Path | None, new_campaign_key: str | None,
                    config_path: Path | None, config_absent: bool,
                    native_path: Path | None, native_absent: bool,
                    role: str, dll_path: Path | None = None) -> dict[str, Any]:
    if not isinstance(role, str) or role not in {"HOST", "CLIENT"}:
        raise ProtocolError("invalid_role")
    for value in (game_build, steam_branch):
        if not value or len(value.encode("utf-8")) > 192:
            raise ProtocolError("game_build_and_steam_branch_required")
    if bool(save_path) == bool(new_campaign_key):
        raise ProtocolError("select_initial_save_or_new_campaign_key")
    if bool(config_path) == bool(config_absent) or bool(native_path) == bool(native_absent):
        raise ProtocolError("declare_config_and_native_file_or_absence")
    manifest = load_json(manifest_path)
    if not isinstance(manifest, dict) or manifest.get("schema") != "mk1212-script-pack-v1" or type(manifest.get("schema_version")) is not int or manifest.get("schema_version") != 1:
        raise ProtocolError("unsupported_pack_manifest_schema")
    source = manifest.get("source_commit_sha", "")
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ProtocolError("manifest_requires_full_source_commit")
    profile = manifest.get("profile", {})
    if not isinstance(profile, dict) or not isinstance(profile.get("name"), str) or profile["name"] not in {"baseline", "full-experimental"}:
        raise ProtocolError("unsupported_pack_profile")
    pack_entry = manifest.get("pack", {})
    if not isinstance(pack_entry, dict) or pack_entry.get("filename") != pack_path.name:
        raise ProtocolError("pack_name_does_not_match_manifest")
    packed = file_identity(pack_path)
    if pack_entry.get("sha256") != packed["sha256"] or str(pack_entry.get("size")) != packed["bytes"]:
        raise ProtocolError("pack_bytes_do_not_match_manifest")
    order = read_load_order(load_order_path, game_directory / "data")
    selected = [item for item in order if item["name"] == pack_path.name.lower()]
    if selected != [{"name": pack_path.name.lower(), **packed}]:
        raise ProtocolError("selected_pack_not_in_actual_load_order_or_wrong_installed_copy")
    overlays = [item for item in order if re.fullmatch(r"mk1212_scripts_.*\.pack", item["name"])]
    if len(overlays) != 1:
        raise ProtocolError("multiple_script_overlays_in_load_order")
    executable = game_directory / "Attila.exe"
    retail = dll_path if dll_path is not None else game_directory / "empire.retail.dll"
    game = {"build_label": game_build, "storefront_declared": "Steam",
            "steam_branch_declared": steam_branch,
            "attila_exe": file_identity(executable),
            "empire_retail_dll": file_identity(retail)}
    if save_path:
        provenance = {"kind": "initial_save", **file_identity(save_path)}
    else:
        if not isinstance(new_campaign_key, str) or not new_campaign_key.strip() or len(new_campaign_key.encode("utf-8")) > 512:
            raise ProtocolError("invalid_new_campaign_key")
        provenance = {"kind": "new_campaign_declared", "key": new_campaign_key}
    compatibility = {
        "schema": PREFLIGHT_SCHEMA, "source_commit_sha": source,
        "profile": profile["name"], "pack": {"name": pack_path.name, **packed},
        "manifest_sha256": file_identity(manifest_path)["sha256"],
        "game": game, "ordered_mods": order, "save_provenance": provenance,
        "local_config": {"present": False} if config_absent else {"present": True, **file_identity(config_path)},
        "native_helper": {"present": False} if native_absent else {"present": True, **file_identity(native_path)},
    }
    return {"schema": PREFLIGHT_SCHEMA, "kind": "mk1212-host-coordinator-preflight",
            "authority": "evidence_only", "role": role,
            "identity_sha256": digest(compatibility), "compatibility": compatibility,
            "local_provenance": {"os": platform.platform(),
                                 "load_order_source": str(load_order_path.resolve()),
                                 "load_order_source_identity": file_identity(load_order_path),
                                 "attila_file_version": windows_file_version(executable),
                                 "empire_file_version": windows_file_version(retail),
                                 "loaded_modules_verified": False,
                                 "actual_engine_mod_order_verified": False}}


def load_preflight(path: Path, role: str | None = None) -> dict[str, Any]:
    value = load_json(path)
    exact_fields(value, {"schema", "kind", "authority", "role", "identity_sha256", "compatibility", "local_provenance"}, "preflight")
    if type(value["schema"]) is not int or value["schema"] != PREFLIGHT_SCHEMA or value["kind"] != "mk1212-host-coordinator-preflight" or value["authority"] != "evidence_only":
        raise ProtocolError("unsupported_preflight_schema")
    if not isinstance(value["role"], str) or value["role"] not in {"HOST", "CLIENT"} or (role is not None and value["role"] != role):
        raise ProtocolError("preflight_role_mismatch")
    if not isinstance(value["identity_sha256"], str) or not SHA256.fullmatch(value["identity_sha256"]) or digest(value["compatibility"]) != value["identity_sha256"]:
        raise ProtocolError("preflight_identity_digest_mismatch")
    compatibility = value["compatibility"]
    exact_fields(compatibility, {"schema", "source_commit_sha", "profile", "pack", "manifest_sha256",
                                  "game", "ordered_mods", "save_provenance", "local_config", "native_helper"},
                 "compatibility")
    if type(compatibility["schema"]) is not int or compatibility["schema"] != PREFLIGHT_SCHEMA:
        raise ProtocolError("unsupported_compatibility_schema")
    if not isinstance(compatibility["source_commit_sha"], str) or not re.fullmatch(r"[0-9a-f]{40}", compatibility["source_commit_sha"]):
        raise ProtocolError("invalid_preflight_source")
    if not isinstance(compatibility["profile"], str) or compatibility["profile"] not in {"baseline", "full-experimental"}:
        raise ProtocolError("invalid_preflight_profile")
    if not isinstance(compatibility["manifest_sha256"], str) or not SHA256.fullmatch(compatibility["manifest_sha256"]):
        raise ProtocolError("invalid_preflight_manifest")
    def validate_file(item: Any, extra: set[str] | None = None) -> None:
        exact_fields(item, {"sha256", "bytes"} | (extra or set()), "preflight_file")
        if not isinstance(item["sha256"], str) or not SHA256.fullmatch(item["sha256"]):
            raise ProtocolError("invalid_preflight_file_hash")
        if not isinstance(item["bytes"], str) or not re.fullmatch(r"0|[1-9][0-9]{0,19}", item["bytes"]):
            raise ProtocolError("invalid_preflight_file_size")
    validate_file(compatibility["pack"], {"name"})
    if not isinstance(compatibility["pack"]["name"], str) or not re.fullmatch(r"mk1212_scripts_[a-z_]+_[0-9a-f]{12}\.pack", compatibility["pack"]["name"]):
        raise ProtocolError("invalid_preflight_pack_name")
    game = compatibility["game"]
    exact_fields(game, {"build_label", "storefront_declared", "steam_branch_declared", "attila_exe", "empire_retail_dll"}, "preflight_game")
    if game["storefront_declared"] != "Steam" or not all(isinstance(game[key], str) and 0 < len(game[key].encode("utf-8")) <= 192 for key in ("build_label", "steam_branch_declared")):
        raise ProtocolError("invalid_preflight_game_declaration")
    validate_file(game["attila_exe"])
    validate_file(game["empire_retail_dll"])
    mods = compatibility["ordered_mods"]
    if not isinstance(mods, list) or not 1 <= len(mods) <= MAX_MODS:
        raise ProtocolError("invalid_preflight_mod_count")
    names = set()
    for mod in mods:
        validate_file(mod, {"name"})
        if not isinstance(mod["name"], str) or not mod["name"].endswith(".pack") or len(mod["name"]) > 512 or mod["name"] in names:
            raise ProtocolError("invalid_preflight_mod_name")
        names.add(mod["name"])
    packed = compatibility["pack"]
    if [{**packed, "name": packed["name"].lower()}] != [item for item in mods if item["name"] == packed["name"].lower()]:
        raise ProtocolError("preflight_pack_not_in_mod_order")
    provenance = compatibility["save_provenance"]
    if not isinstance(provenance, dict):
        raise ProtocolError("invalid_save_provenance")
    if provenance.get("kind") == "initial_save":
        validate_file(provenance, {"kind"})
    elif provenance.get("kind") == "new_campaign_declared":
        exact_fields(provenance, {"kind", "key"}, "new_campaign")
        if not isinstance(provenance["key"], str) or not 0 < len(provenance["key"].encode("utf-8")) <= 512:
            raise ProtocolError("invalid_new_campaign_key")
    else:
        raise ProtocolError("unknown_save_provenance")
    for key in ("local_config", "native_helper"):
        item = compatibility[key]
        if not isinstance(item, dict) or type(item.get("present")) is not bool:
            raise ProtocolError("invalid_optional_file_presence")
        if item["present"]:
            validate_file(item, {"present"})
        else:
            exact_fields(item, {"present"}, "absent_file")
    return value


def write_preflight(path: Path, **kwargs: Any) -> dict[str, Any]:
    result = build_preflight(**kwargs)
    atomic_json(path, result, replace=False)
    return result
