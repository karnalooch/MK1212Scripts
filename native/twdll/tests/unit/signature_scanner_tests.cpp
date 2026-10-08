#include "common/signature_scanner.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <sstream>
#include <string>
#include <vector>

namespace {

int failures = 0;

void expect(bool condition, const char* name) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", name);
        ++failures;
    }
}

uint32_t next_random(uint32_t& state) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

std::string make_signature(const std::vector<uint8_t>& pattern, int wildcard_index = -1) {
    std::ostringstream out;
    out << std::hex;
    for (size_t i = 0; i < pattern.size(); ++i) {
        if (i != 0) out << ' ';
        if (static_cast<int>(i) == wildcard_index) {
            out << "??";
        } else {
            static constexpr char digits[] = "0123456789ABCDEF";
            out << digits[(pattern[i] >> 4) & 0xF] << digits[pattern[i] & 0xF];
        }
    }
    return out.str();
}

void run_deterministic_fuzz() {
    constexpr size_t kHaystackSize = 512;
    constexpr int kIterations = 5000;
    uint32_t rng = 0x1212A771u;

    for (int iteration = 0; iteration < kIterations; ++iteration) {
        const size_t pattern_len = 1 + (next_random(rng) % 24);
        const size_t position = next_random(rng) % (kHaystackSize - pattern_len + 1);

        std::array<uint8_t, kHaystackSize> haystack{};
        haystack.fill(0xA5);

        std::vector<uint8_t> pattern(pattern_len);
        pattern[0] = 0x5A;
        for (size_t i = 1; i < pattern_len; ++i) {
            uint8_t value = static_cast<uint8_t>(next_random(rng) & 0xFF);
            if (value == 0xA5 || value == 0x5A) value ^= 0x3C;
            pattern[i] = value;
        }

        for (size_t i = 0; i < pattern_len; ++i) {
            haystack[position + i] = pattern[i];
        }

        const uintptr_t base = reinterpret_cast<uintptr_t>(haystack.data());
        const std::string exact = make_signature(pattern);
        if (Scanner::find_signature(base, haystack.size(), exact.c_str()) != base + position) {
            std::fprintf(stderr, "FAIL: fuzz exact match iteration=%d position=%zu len=%zu\n",
                         iteration, position, pattern_len);
            ++failures;
            return;
        }

        if (pattern_len > 2) {
            const int wildcard = 1 + static_cast<int>(next_random(rng) % (pattern_len - 1));
            const std::string masked = make_signature(pattern, wildcard);
            if (Scanner::find_signature(base, haystack.size(), masked.c_str()) != base + position) {
                std::fprintf(stderr, "FAIL: fuzz wildcard match iteration=%d position=%zu len=%zu\n",
                             iteration, position, pattern_len);
                ++failures;
                return;
            }
        }
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
    expect(Scanner::find_signature(base, sizeof(bytes), "?? ??") == base,
           "all-wildcard pattern starts at base");
    expect(Scanner::find_signature(base, sizeof(bytes), "CC DD") == base + 2,
           "signature at final valid offset");
    expect(Scanner::find_signature(base, sizeof(bytes), "AA BB CC DD EE") == 0,
           "oversized signature fails closed");
    expect(Scanner::find_signature(base, sizeof(bytes), "") == 0,
           "empty signature fails closed");
    expect(Scanner::find_signature(base, sizeof(bytes), nullptr) == 0,
           "null signature fails closed");
    expect(Scanner::find_signature(0, sizeof(bytes), "AA") == 0,
           "null base fails closed");
    expect(Scanner::find_signature(base, 0, "AA") == 0,
           "zero-sized range fails closed");
    expect(Scanner::find_signature(base, sizeof(bytes), "GG") == 0,
           "malformed signature fails closed");
    expect(Scanner::find_signature(base, sizeof(bytes), "100") == 0,
           "out-of-byte-range token fails closed");

    const char strings[] = {'x', '\0', 'n', 'e', 'e', 'd', 'l', 'e', '\0'};
    const uintptr_t strings_base = reinterpret_cast<uintptr_t>(strings);
    expect(Scanner::FindString(strings_base, sizeof(strings), "needle") == strings_base + 2,
           "null-terminated string found");
    expect(Scanner::FindString(strings_base, sizeof(strings), "") == 0,
           "empty string needle fails closed");
    expect(Scanner::FindString(0, sizeof(strings), "needle") == 0,
           "null string base fails closed");

    const char unterminated[] = {'n', 'e', 'e', 'd', 'l', 'e'};
    expect(Scanner::FindString(reinterpret_cast<uintptr_t>(unterminated), sizeof(unterminated), "needle") == 0,
           "unterminated boundary string rejected");

    const uint8_t push_ref[] = {0x90, 0x68, 0x78, 0x56, 0x34, 0x12};
    expect(Scanner::FindPushRef(reinterpret_cast<uintptr_t>(push_ref), sizeof(push_ref), 0x12345678u)
               == reinterpret_cast<uintptr_t>(push_ref) + 1,
           "x86 push immediate reference found");
    expect(Scanner::FindPushRef(reinterpret_cast<uintptr_t>(push_ref), 4, 0x12345678u) == 0,
           "truncated x86 push range rejected");

    const uint8_t function_bytes[] = {0xCC, 0x55, 0x8B, 0xEC, 0x90, 0x68, 0, 0, 0, 0};
    const uintptr_t function_base = reinterpret_cast<uintptr_t>(function_bytes);
    expect(Scanner::FindPrologue(function_base + 5, 5) == function_base + 1,
           "function prologue found without unsigned wraparound");
    expect(Scanner::FindPrologue(0, 0x10) == 0,
           "invalid prologue origin fails closed");
    expect(Scanner::FindPrologue(function_base + 5, 0) == 0,
           "zero prologue range fails closed");

    run_deterministic_fuzz();

    if (failures == 0) {
        std::puts("twdll signature scanner tests: PASS (5000 deterministic fuzz iterations)");
        return 0;
    }

    std::fprintf(stderr, "twdll signature scanner tests: %d failure(s)\n", failures);
    return 1;
}
