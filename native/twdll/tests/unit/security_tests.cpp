#include "attila/security.h"

#include <cstdio>

namespace {

int failures = 0;

void expect(bool condition, const char* name) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", name);
        ++failures;
    }
}

} // namespace

int main() {
    expect(is_attila_executable_path("C:\\Games\\Total War Attila\\Attila.exe"),
           "canonical Attila executable path accepted");
    expect(is_attila_executable_path("c:/games/ATTILA.EXE"),
           "case-insensitive Attila basename accepted");
    expect(is_attila_executable_path("Attila.exe"),
           "bare Attila executable basename accepted");

    expect(!is_attila_executable_path(nullptr),
           "null executable path rejected");
    expect(!is_attila_executable_path(""),
           "empty executable path rejected");
    expect(!is_attila_executable_path("C:\\Games\\notattila.exe"),
           "substring executable name rejected");
    expect(!is_attila_executable_path("C:\\Games\\attila.exe.bak"),
           "suffix executable name rejected");
    expect(!is_attila_executable_path("C:\\Games\\attila.exe\\helper.exe"),
           "directory component named attila.exe rejected");

    expect(!is_valid_game_host(),
           "native test process is rejected as an Attila host");

    if (failures == 0) {
        std::puts("twdll security guard tests: PASS");
        return 0;
    }

    std::fprintf(stderr, "twdll security guard tests: %d failure(s)\n", failures);
    return 1;
}
