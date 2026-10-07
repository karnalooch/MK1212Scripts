#include "game_api.h"
#include "signature_scanner.h"
#include "log.h"
#include <windows.h>
#include <psapi.h>

extern const char* GAME_MODULE_NAME;

void initialize_game_api() {
    HMODULE hMod = GetModuleHandleA(GAME_MODULE_NAME);
    if (!hMod) {
        Log("[twdll] initialize_game_api: %s not found", GAME_MODULE_NAME);
        g_empire_module = nullptr;
        return;
    }

    MODULEINFO mi = {};
    if (!GetModuleInformation(GetCurrentProcess(), hMod, &mi, sizeof(mi))) {
        Log("[twdll] initialize_game_api: GetModuleInformation failed (%lu)", GetLastError());
        g_empire_module = nullptr;
        return;
    }
    g_empire_module = hMod;

    uintptr_t base = reinterpret_cast<uintptr_t>(hMod);
    size_t    size = mi.SizeOfImage;
    size_t    total = 0;
    size_t    resolved = 0;

    for (const TW_GameSigInfo* s = g_game_signatures; s->name; ++s) {
        ++total;
        if (s->target) {
            *s->target = nullptr;
        }
        if (!s->sig || s->sig[0] == '\0') {
            Log("[twdll] initialize_game_api: empty signature — %s", s->name);
            continue;
        }

        uintptr_t addr = Scanner::find_signature(base, size, s->sig);
        if (!addr || !s->target) {
            Log("[twdll] initialize_game_api: not found — %s", s->name);
            continue;
        }

        *s->target = reinterpret_cast<void*>(addr);
        ++resolved;
        Log("[twdll] initialize_game_api: %s @ 0x%08X", s->name, addr);
    }

    if (resolved != total) {
        Log("[twdll] initialize_game_api: DEGRADED (%zu/%zu game signatures resolved); affected features stay unavailable",
            resolved, total);
    } else {
        Log("[twdll] initialize_game_api: complete (%zu/%zu game signatures resolved)", resolved, total);
    }
}
