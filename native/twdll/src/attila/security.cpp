#include "attila/security.h"
#include <windows.h>
#include <string>
#include <algorithm>
#include <cctype>

bool is_valid_game_host() {
    char exe_path[MAX_PATH] = {0};
    if (GetModuleFileNameA(NULL, exe_path, MAX_PATH) == 0) {
        return false;
    }

    std::string path_lower(exe_path);
    std::transform(path_lower.begin(), path_lower.end(), path_lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });

    const size_t slash = path_lower.find_last_of("\\/");
    const std::string exe_name = (slash == std::string::npos)
        ? path_lower
        : path_lower.substr(slash + 1);

    if (exe_name != "attila.exe") {
        return false;
    }

    if (GetModuleHandleA("empire.retail.dll") == NULL) {
        return false;
    }

    return true;
}
