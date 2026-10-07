#include "common/signature_scanner.h"

#include <cstdint>
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
    const uint8_t bytes[] = {0xAA, 0xBB, 0xCC, 0xDD};
    const uintptr_t base = reinterpret_cast<uintptr_t>(bytes);

    expect(Scanner::find_signature(base, sizeof(bytes), "AA BB") == base,
           "signature at first byte");
    expect(Scanner::find_signature(base, sizeof(bytes), "AA ?? CC") == base,
           "signature wildcard");
    expect(Scanner::find_signature(base, sizeof(bytes), "CC DD") == base + 2,
           "signature at final valid offset");
    expect(Scanner::find_signature(base, sizeof(bytes), "AA BB CC DD EE") == 0,
           "oversized signature fails closed");
    expect(Scanner::find_signature(base, sizeof(bytes), "") == 0,
           "empty signature fails closed");
    expect(Scanner::find_signature(base, sizeof(bytes), nullptr) == 0,
           "null signature fails closed");
    expect(Scanner::find_signature(base, sizeof(bytes), "GG") == 0,
           "malformed signature fails closed");

    const char strings[] = {'x', '\0', 'n', 'e', 'e', 'd', 'l', 'e', '\0'};
    const uintptr_t strings_base = reinterpret_cast<uintptr_t>(strings);
    expect(Scanner::FindString(strings_base, sizeof(strings), "needle") == strings_base + 2,
           "null-terminated string found");

    const char unterminated[] = {'n', 'e', 'e', 'd', 'l', 'e'};
    expect(Scanner::FindString(reinterpret_cast<uintptr_t>(unterminated), sizeof(unterminated), "needle") == 0,
           "unterminated boundary string rejected");

    const uint8_t push_ref[] = {0x90, 0x68, 0x78, 0x56, 0x34, 0x12};
    expect(Scanner::FindPushRef(reinterpret_cast<uintptr_t>(push_ref), sizeof(push_ref), 0x12345678u)
               == reinterpret_cast<uintptr_t>(push_ref) + 1,
           "x86 push immediate reference found");

    const uint8_t function_bytes[] = {0xCC, 0x55, 0x8B, 0xEC, 0x90, 0x68, 0, 0, 0, 0};
    const uintptr_t function_base = reinterpret_cast<uintptr_t>(function_bytes);
    expect(Scanner::FindPrologue(function_base + 5, 5) == function_base + 1,
           "function prologue found without unsigned wraparound");
    expect(Scanner::FindPrologue(0, 0x10) == 0,
           "invalid prologue origin fails closed");

    if (failures == 0) {
        std::puts("twdll signature scanner tests: PASS");
        return 0;
    }

    std::fprintf(stderr, "twdll signature scanner tests: %d failure(s)\n", failures);
    return 1;
}
