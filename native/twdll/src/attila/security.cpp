#include "attila/security.h"
#include <windows.h>
#include <string>
#include <algorithm>
#include <cctype>

bool is_attila_executable_path(const char* exe_path) {
    if (!exe_path || exe_path[0] == '\0') {
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

    return exe_name == "attila.exe";
}

bool is_valid_game_host() {
    char exe_path[MAX_PATH] = {0};
    if (GetModuleFileNameA(NULL, exe_path, MAX_PATH) == 0) {
        return false;
    }

    if (!is_attila_executable_path(exe_path)) {
        return false;
    }

    return GetModuleHandleA("empire.retail.dll") != NULL;
}
