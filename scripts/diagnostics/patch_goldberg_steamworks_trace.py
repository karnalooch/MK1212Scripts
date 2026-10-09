#!/usr/bin/env python3
"""Prepare a fail-closed, source-pinned Goldberg Steamworks trace build (source only).

This does NOT compile a DLL or modify any game installation.
Input: checked-out original Mr_Goldberg source at 475342f0.
Output: separate source tree with bounded, low-volume API/callback tracing.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

UPSTREAM_COMMIT = "475342f0d8b2bd7eb0d93bd7cfdd61e3ae7cda24"
PINNED_BLOBS = {
    "dll/steam_matchmaking.h": "94bd026b0d531ae21bf25e231d2320154d1cce28",
    "dll/steam_matchmaking_servers.cpp": "23441f353ad853b74437260c89aac5fb937ec2de",
    "dll/steam_friends.h": "5f28c95f80d393cf4a7274fa08ff4d3f769e012b",
}

HEADER = r'''// MK1212 narrow instrumentation for an isolated, pinned Goldberg build.
// LGPL-3.0-or-later (derivative of Goldberg); no external contacts or secrets.
#ifndef MK1212_STEAMWORKS_TRACE_H
#define MK1212_STEAMWORKS_TRACE_H
#include <cstdio>
#include <cstdarg>
#include <ctime>
#include <windows.h>
static inline void mk1212_trace(const char *event, const char *fmt, ...) {
    FILE *out = std::fopen("MK1212_STEAMWORKS_TRACE.log", "ab");
    if (!out) return;
    if (std::fseek(out, 0, SEEK_END) != 0 || std::ftell(out) >= 2097152L) {
        std::fclose(out);
        return;
    }
    std::fprintf(out, "%lld|%lu|%s|",
        static_cast<long long>(std::time(nullptr)),
        static_cast<unsigned long>(GetCurrentProcessId()), event);
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(out, fmt, ap);
    va_end(ap);
    std::fputc('\n', out);
    std::fclose(out);
}
#endif
'''

def git_blob(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()

def replace_exact(text: str, old: str, new: str, expected: int = 1) -> str:
    found = text.count(old)
    if found != expected:
        raise RuntimeError(f"Anchor mismatch: expected {expected}, saw {found}: {old[:110]!r}")
    return text.replace(old, new)

def patch_matchmaking(text: str) -> str:
    text = replace_exact(text, '#include "base.h"', '#include "base.h"\n#include "mk1212_steamworks_trace.h"')
    text = replace_exact(text,
        'PRINT_DEBUG("CreateLobby type: %i max_members: %i\\n", eLobbyType, cMaxMembers);',
        'PRINT_DEBUG("CreateLobby type: %i max_members: %i\\n", eLobbyType, cMaxMembers);\n'
        '    mk1212_trace("CreateLobby.call", "type=%d members=%d", static_cast<int>(eLobbyType), cMaxMembers);')
    text = replace_exact(text, 'return p_c.api_id;',
        'mk1212_trace("CreateLobby.return", "call=%llu", static_cast<unsigned long long>(p_c.api_id));\n'
        '    return p_c.api_id;')
    text = replace_exact(text, 'PRINT_DEBUG("RequestLobbyList\\n");',
        'PRINT_DEBUG("RequestLobbyList\\n");\n    mk1212_trace("RequestLobbyList.call", "begin=1");')
    text = replace_exact(text, 'return search_call_api_id;',
        'mk1212_trace("RequestLobbyList.return", "call=%llu", static_cast<unsigned long long>(search_call_api_id));\n'
        '    return search_call_api_id;')
    text = replace_exact(text,
        'data.m_nLobbiesMatching = filtered_lobbies.size();',
        'data.m_nLobbiesMatching = filtered_lobbies.size();\n'
        '                mk1212_trace("LobbyMatchList.callback", "call=%llu matches=%u", '
        'static_cast<unsigned long long>(search_call_api_id), static_cast<unsigned>(data.m_nLobbiesMatching));',
        2)
    text = replace_exact(text, 'data.m_eResult = k_EResultFail;',
        'data.m_eResult = k_EResultFail;\n'
        '                mk1212_trace("LobbyCreated.callback", "result=fail call=%llu lobby=0", '
        'static_cast<unsigned long long>(p_c->api_id));')
    text = replace_exact(text, 'data.m_eResult = k_EResultOK;',
        'data.m_eResult = k_EResultOK;\n'
        '                mk1212_trace("LobbyCreated.callback", "result=ok call=%llu lobby=%llu", '
        'static_cast<unsigned long long>(p_c->api_id), '
        'static_cast<unsigned long long>(lobby.room_id()));')
    text = replace_exact(text, 'PRINT_DEBUG("JoinLobby %llu\\n", steamIDLobby.ConvertToUint64());',
        'PRINT_DEBUG("JoinLobby %llu\\n", steamIDLobby.ConvertToUint64());\n'
        '    mk1212_trace("JoinLobby.call", "lobby=%llu", '
        'static_cast<unsigned long long>(steamIDLobby.ConvertToUint64()));')
    text = replace_exact(text, 'PRINT_DEBUG("InviteUserToLobby\\n");',
        'PRINT_DEBUG("InviteUserToLobby\\n");\n'
        '    mk1212_trace("InviteUserToLobby.call", "lobby=%llu invitee=%llu", '
        'static_cast<unsigned long long>(steamIDLobby.ConvertToUint64()), '
        'static_cast<unsigned long long>(steamIDInvitee.ConvertToUint64()));')
    # Do not log keys or values: they can contain passwords or game metadata.
    text = replace_exact(text, 'PRINT_DEBUG("SetLobbyData %llu %s %s\\n", steamIDLobby.ConvertToUint64(), pchKey, pchValue);',
        'PRINT_DEBUG("SetLobbyData %llu %s %s\\n", steamIDLobby.ConvertToUint64(), pchKey, pchValue);\n'
        '    mk1212_trace("SetLobbyData.call", "lobby=%llu key_present=%d value_present=%d", '
        'static_cast<unsigned long long>(steamIDLobby.ConvertToUint64()), '
        'pchKey != nullptr, pchValue != nullptr);')
    return text

def patch_servers(text: str) -> str:
    text = replace_exact(text, '#include "steam_matchmaking_servers.h"',
        '#include "steam_matchmaking_servers.h"\n#include "mk1212_steamworks_trace.h"')
    text = replace_exact(text, 'PRINT_DEBUG("RequestLANServerList %u\\n", iApp);',
        'PRINT_DEBUG("RequestLANServerList %u\\n", iApp);\n'
        '    mk1212_trace("RequestLANServerList.call", "appid=%u interface=new", '
        'static_cast<unsigned>(iApp));')
    text = replace_exact(text, 'HServerListRequest id = requests[requests.size() - 1].id;',
        'HServerListRequest id = requests[requests.size() - 1].id;\n'
        '    mk1212_trace("RequestLANServerList.return", "appid=%u interface=new", '
        'static_cast<unsigned>(iApp));')
    text = replace_exact(text,
        'RequestOldServerList(iApp, pRequestServersResponse, eLANServer);',
        'mk1212_trace("RequestLANServerList.call", "appid=%u interface=old", '
        'static_cast<unsigned>(iApp));\n'
        '    RequestOldServerList(iApp, pRequestServersResponse, eLANServer);')
    text = replace_exact(text, 'if (r.callbacks) {',
        'mk1212_trace("ServerList.callback", "interface=new appid=%u matches=%u", '
        'static_cast<unsigned>(r.appid), static_cast<unsigned>(r.gameservers_filtered.size()));\n'
        '        if (r.callbacks) {')
    text = replace_exact(text, 'if (r.old_callbacks) {',
        'mk1212_trace("ServerList.callback", "interface=old appid=%u matches=%u", '
        'static_cast<unsigned>(r.appid), static_cast<unsigned>(r.gameservers_filtered.size()));\n'
        '        if (r.old_callbacks) {')
    return text

def patch_friends(text: str) -> str:
    text = replace_exact(text, '#include "base.h"',
        '#include "base.h"\n#include "mk1212_steamworks_trace.h"')
    text = replace_exact(text, 'PRINT_DEBUG("Steam_Friends::InviteUserToGame\\n");',
        'PRINT_DEBUG("Steam_Friends::InviteUserToGame\\n");\n'
        '    mk1212_trace("InviteUserToGame.call", "friend=%llu connect_present=%d", '
        'static_cast<unsigned long long>(steamIDFriend.ConvertToUint64()), '
        'pchConnectString != nullptr);')
    text = replace_exact(text, 'PRINT_DEBUG("Steam_Friends::ActivateGameOverlayInviteDialog\\n");',
        'PRINT_DEBUG("Steam_Friends::ActivateGameOverlayInviteDialog\\n");\n'
        '    mk1212_trace("ActivateGameOverlayInviteDialog.call", "lobby=%llu", '
        'static_cast<unsigned long long>(steamIDLobby.ConvertToUint64()));')
    return text

PATCHERS = {
    "dll/steam_matchmaking.h": patch_matchmaking,
    "dll/steam_matchmaking_servers.cpp": patch_servers,
    "dll/steam_friends.h": patch_friends,
}

def prepare(source: Path, output: Path) -> dict:
    source, output = source.resolve(), output.resolve()
    if not source.is_dir() or source == output or source in output.parents or output in source.parents:
        raise RuntimeError("Source/output must be separate, existing/empty-safe directories.")
    if output.exists():
        raise RuntimeError("Refusing existing output; no inplace rewrite or implicit retry.")
    # All validation and transformation precedes ANY write.
    patched = {}
    verified = {}
    for rel, patcher in PATCHERS.items():
        src = source / rel
        data = src.read_bytes()
        # Windows checkout may use CRLF; normalize before calculating Git object.
        normalized = data.replace(b"\r\n", b"\n")
        blob = git_blob(normalized)
        if blob != PINNED_BLOBS[rel]:
            raise RuntimeError(f"Unpinned Goldberg input {rel}: observed {blob}, expected {PINNED_BLOBS[rel]}")
        updated = patcher(normalized.decode("utf-8"))
        patched[rel] = updated.encode("utf-8")
        verified[rel] = {"git_blob":blob,"source_sha256":hashlib.sha256(normalized).hexdigest(),
                         "patched_sha256":hashlib.sha256(patched[rel]).hexdigest()}
    shutil.copytree(source, output, ignore=shutil.ignore_patterns(".git"))
    for rel, data in patched.items():
        (output / rel).write_bytes(data)
    (output / "dll/mk1212_steamworks_trace.h").write_text(HEADER, encoding="utf-8", newline="\n")
    manifest = {"schema":1, "source_commit":UPSTREAM_COMMIT, "source_files":verified,
                "trace_header_sha256":hashlib.sha256(HEADER.encode()).hexdigest(),
                "compile_status":"NOT_BUILT", "multiplayer_status":"NOT_TESTED"}
    (output / "MK1212-STEAMWORKS-TRACE-SOURCE.json").write_text(
        json.dumps(manifest, indent=2) + "\n",encoding="utf-8")
    return manifest

def main(argv=None) -> int:
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source",required=True,type=Path,help="Pinned Goldberg source checkout")
    ap.add_argument("--output",required=True,type=Path,help="New clean output folder, separate from game")
    args=ap.parse_args(argv)
    try:
        result=prepare(args.source,args.output)
    except (OSError,ValueError,RuntimeError,UnicodeError) as exc:
        print("MK1212 TRACE BLOCKED:", exc,file=sys.stderr)
        return 2
    print(json.dumps(result,indent=2))
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
