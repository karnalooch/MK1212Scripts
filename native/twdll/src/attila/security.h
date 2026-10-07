#pragma once

// Pure executable-path check used by the process host guard and native tests.
bool is_attila_executable_path(const char* exe_path);

// Valid only when the current process is Attila.exe and empire.retail.dll is loaded.
bool is_valid_game_host();
