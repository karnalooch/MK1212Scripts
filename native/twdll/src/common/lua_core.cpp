#include "tw.h"

extern const char* GAME_NAME;

/// @module twdll.core
/// Utility functions available in all games.

#include <string>

/// Log a message or arbitrary values to `twdll.log`.
/// Accepts any number of arguments of any type, converting them via Lua tostring.
/// @function Log
/// @tparam any ... values to log
/// @usage
/// twdll.core.Log("Campaign initialized. Turn:", 1, "Faction:", faction:name())
static int script_Log(lua_State* L) {
    static constexpr size_t kMaxScriptLogChars = 4096;
    static constexpr int kMaxScriptLogArgs = 64;

    std::string full_msg;
    full_msg.reserve(kMaxScriptLogChars);
    bool truncated = false;

    auto append_bounded = [&](const char* data, size_t len) {
        if (!data || len == 0 || full_msg.size() >= kMaxScriptLogChars) {
            if (len > 0) truncated = true;
            return;
        }
        const size_t remaining = kMaxScriptLogChars - full_msg.size();
        const size_t count = (len < remaining) ? len : remaining;
        full_msg.append(data, count);
        if (count < len) truncated = true;
    };

    int i = 1;
    for (; i <= kMaxScriptLogArgs && l_type(L, i) != LUA_TNONE; ++i) {
        if (i > 1) append_bounded("\t", 1);
        l_getfield(L, LUA_GLOBALSINDEX, "tostring");
        l_pushvalue(L, i);
        if (l_pcall(L, 1, 1, 0) == 0) {
            size_t len = 0;
            if (const char* s = l_checklstring(L, -1, &len)) {
                append_bounded(s, len);
            }
            l_pop(L, 1);
        } else {
            l_pop(L, 1);
        }
    }
    if (l_type(L, i) != LUA_TNONE) truncated = true;

    if (truncated) {
        static constexpr char marker[] = " [truncated]";
        constexpr size_t marker_len = sizeof(marker) - 1;
        if (full_msg.size() + marker_len > kMaxScriptLogChars) {
            full_msg.resize(kMaxScriptLogChars - marker_len);
        }
        full_msg.append(marker, marker_len);
    }

    Log("%s", full_msg.c_str());
    return 0;
}

/// Returns the target game build name (e.g. `"Attila"`).
/// @function GameBuild
/// @treturn string game name
/// @usage
/// local game_name = twdll.core.GameBuild()
static int script_GameBuild(lua_State* L) {
    l_pushstring(L, GAME_NAME);
    return 1;
}

#ifndef TWDLL_BUILD_SHA
#define TWDLL_BUILD_SHA "unknown"
#endif

/// Returns the git commit SHA hash from which the DLL was compiled.
/// @function GetBuildSha
/// @treturn string 40-character hexadecimal git commit SHA
/// @usage
/// local sha = twdll.core.GetBuildSha()
static int script_GetBuildSha(lua_State* L) {
    l_pushstring(L, TWDLL_BUILD_SHA);
    return 1;
}

extern const luaL_Reg twdll_core[] = {
    {"Log",         script_Log},
    {"GameBuild",   script_GameBuild},
    {"GetBuildSha", script_GetBuildSha},
    {nullptr, nullptr}
};
