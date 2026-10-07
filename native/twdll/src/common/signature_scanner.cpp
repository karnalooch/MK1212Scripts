#include "signature_scanner.h"
#include <cstdint>
#include <cstring>

namespace Scanner {

static bool byte_matches(const unsigned char byte, const unsigned char pattern_byte, const unsigned char mask_byte) {
    return (byte & mask_byte) == (pattern_byte & mask_byte);
}

uintptr_t find_signature(uintptr_t base_address, size_t size, const char* signature_str) {
    if (!base_address || size == 0 || !signature_str) {
        return 0;
    }

    std::vector<unsigned char> signature_bytes;
    std::vector<unsigned char> mask_bytes;

    std::stringstream ss_sig(signature_str);
    std::string byte_hex;
    while (ss_sig >> byte_hex) {
        if (byte_hex == "??" || byte_hex == "?") {
            signature_bytes.push_back(0x00);
            mask_bytes.push_back(0x00);
            continue;
        }

        try {
            size_t parsed = 0;
            unsigned long value = std::stoul(byte_hex, &parsed, 16);
            if (parsed != byte_hex.size() || value > 0xFF) {
                return 0;
            }
            signature_bytes.push_back(static_cast<unsigned char>(value));
            mask_bytes.push_back(0xFF);
        } catch (...) {
            return 0;
        }
    }

    if (signature_bytes.empty() || signature_bytes.size() > size) {
        return 0;
    }

    const size_t last_start = size - signature_bytes.size();
    for (size_t i = 0; i <= last_start; ++i) {
        bool found = true;
        for (size_t j = 0; j < signature_bytes.size(); ++j) {
            if (!byte_matches(*reinterpret_cast<const unsigned char*>(base_address + i + j),
                              signature_bytes[j], mask_bytes[j])) {
                found = false;
                break;
            }
        }
        if (found) {
            return base_address + i;
        }
    }
    return 0;
}

uintptr_t FindString(uintptr_t base, size_t size, const char* needle) {
    if (!base || size == 0 || !needle) return 0;
    size_t nlen = strlen(needle);
    if (nlen == 0 || nlen >= size) return 0;

    const char* mem = reinterpret_cast<const char*>(base);
    const size_t last_start = size - nlen - 1;
    for (size_t i = 0; i <= last_start; ++i) {
        if (memcmp(mem + i, needle, nlen) == 0 && mem[i + nlen] == '\0')
            return base + i;
    }
    return 0;
}

uintptr_t FindPushRef(uintptr_t text_base, size_t text_size, uintptr_t target_addr) {
    if (!text_base || text_size < 5) return 0;

    const uint8_t* mem = reinterpret_cast<const uint8_t*>(text_base);
    for (size_t i = 0; i + 5 <= text_size; ++i) {
        if (mem[i] == 0x68) {
            uint32_t imm = 0;
            memcpy(&imm, mem + i + 1, sizeof(imm));
            if (imm == static_cast<uint32_t>(target_addr))
                return text_base + i;
        }
    }
    return 0;
}

static bool is_prologue(const uint8_t* p) {
    if (p[0] == 0x55 && p[1] == 0x8B && p[2] == 0xEC)
        return true;
    if (p[0] == 0x55 && p[1] == 0x8B && p[2] == 0xED)
        return true;
    if (p[0] == 0x81 && p[1] == 0xEC)
        return true;
    if (p[0] == 0x83 && p[1] == 0xEC)
        return true;
    if (p[0] == 0x53 && p[1] == 0x55 && p[2] == 0x56 && p[3] == 0x57)
        return true;
    if (p[0] == 0x53 && p[1] == 0x56 && p[2] == 0x57 && p[3] == 0x8B && p[4] == 0xF9)
        return true;
    return false;
}

uintptr_t FindPrologue(uintptr_t from_addr, size_t max_back) {
    if (from_addr <= 1 || max_back == 0) return 0;

    const uintptr_t start = (from_addr > max_back) ? from_addr - max_back : 1;
    for (uintptr_t addr = from_addr - 1;; --addr) {
        const uint8_t* p = reinterpret_cast<const uint8_t*>(addr);
        if (is_prologue(p)) {
            uint8_t prev = *reinterpret_cast<const uint8_t*>(addr - 1);
            if (prev == 0xCC || prev == 0x90) {
                return addr;
            }
        }
        if (addr == start) break;
    }
    return 0;
}

} // namespace Scanner
